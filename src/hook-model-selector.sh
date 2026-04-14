#!/usr/bin/env bash
# ModelSelector Hook - Layer 2: In-session routing
# Installed as a UserPromptSubmit hook in Claude Code settings.json
# Reads the prompt from stdin, scores it, and outputs a routing recommendation
# that Claude (Opus) reads and acts on by dispatching sub-agents.
#
# When tier < T4, output instructs Claude to delegate to a cheaper model.
# When tier = T4, output nothing (silent, let Opus handle normally).

# Note: do NOT use set -e here. The scoring engine uses grep (exit 1 on no match)
# and arithmetic comparisons that return exit 1 when false. These are expected
# behavior, not errors. A hook must never crash silently.

MS_LOG="${HOME}/.claude/model-selector.log"

SELECTOR="${HOME}/.claude/hooks/model-selector-engine.sh"

# Fallback: if engine not installed at hook location, try repo location
if [[ ! -x "$SELECTOR" ]]; then
    SELECTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-selector.sh"
fi

if [[ ! -x "$SELECTOR" ]]; then
    echo "[$(date)] ERROR: selector not found" >> "$MS_LOG" 2>/dev/null
    exit 0
fi

# Read prompt from stdin
# Claude Code passes JSON: {"session_id":"...","transcript_path":"...","prompt":"..."}
# Extract the prompt field; fall back to raw stdin for manual testing.
RAW_STDIN=$(cat)
PROMPT=$(echo "$RAW_STDIN" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('prompt', ''), end='')
except Exception:
    pass
" 2>/dev/null)

# If python3 extraction failed or returned empty, use raw stdin as fallback
if [[ -z "$PROMPT" ]]; then
    PROMPT="$RAW_STDIN"
fi

if [[ -z "$PROMPT" ]]; then
    exit 0
fi

# Skip very short prompts (4 chars - Chinese is dense)
if [[ ${#PROMPT} -lt 4 ]]; then
    exit 0
fi

# Skip meta-questions about ModelSelector itself
if echo "$PROMPT" | grep -qiE '(model.?select|model.?rout|模型.*选择|模型.*路由)'; then
    exit 0
fi

# Get routing decision as JSON
result=$(echo "$PROMPT" | "$SELECTOR" --json 2>/dev/null)
if [[ -z "$result" ]]; then
    echo "[$(date)] ERROR: selector returned empty for: ${PROMPT:0:80}" >> "$MS_LOG" 2>/dev/null
    exit 0
fi

# Parse JSON fields into separate lines (NUL-separated for safety)
# Fields come from the scoring engine which derives them from prompt patterns.
# We use read -r with explicit delimiter to avoid eval injection.
parse_output=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# Output tab-separated fields in fixed order: tier, tier_name, model, tools, capability, is_peak
print('\t'.join([
    str(d['tier']),
    d['tier_name'],
    d['model'],
    d['tools'],
    d['capability'],
    str(d['peak']).lower(),
    str(d.get('correction', False)).lower(),
]))
" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$parse_output" ]]; then
    echo "[$(date)] ERROR: JSON parse failed for: ${PROMPT:0:80}" >> "$MS_LOG" 2>/dev/null
    exit 0
fi

# Safely read tab-separated values into named variables (no eval)
IFS=$'\t' read -r tier tier_name model tools capability is_peak correction <<< "$parse_output"

# Validate tier is a single digit (defense in depth)
if ! [[ "$tier" =~ ^[0-9]$ ]]; then
    echo "[$(date)] ERROR: invalid tier value: $tier" >> "$MS_LOG" 2>/dev/null
    exit 0
fi

# Log routing decision (skip prompt content when P0 privacy override fired to avoid logging secrets)
if [[ "$tier" == "0" ]] && echo "$PROMPT" | grep -qiE '(password|passwd|api.?key|secret|token|bearer|credential|private.?key)'; then
    echo "[$(date)] ${tier_name} | ${capability} | tools=${tools} | corr=${correction} | [REDACTED:privacy]" >> "$MS_LOG" 2>/dev/null
else
    echo "[$(date)] ${tier_name} | ${capability} | tools=${tools} | corr=${correction} | ${PROMPT:0:80}" >> "$MS_LOG" 2>/dev/null
fi

# RTK adaptive limits: adjust compression aggressiveness based on routed tier
RTK_STATS_BRIDGE="${HOME}/.claude/hooks/rtk-stats.sh"
if [[ ! -x "$RTK_STATS_BRIDGE" ]]; then
    RTK_STATS_BRIDGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rtk-stats.sh"
fi
if [[ -x "$RTK_STATS_BRIDGE" ]]; then
    "$RTK_STATS_BRIDGE" --adapt-limits "$tier" 2>/dev/null &
fi

# RTK quality alert: warn if tee recovery rate is high
RTK_STATS="${HOME}/.config/model-selector/rtk-stats.json"
RTK_ALERT=""
if [[ -f "$RTK_STATS" ]]; then
    RTK_ALERT=$(python3 -c "
import json
d = json.load(open('$RTK_STATS'))
if d.get('rtk_active') and float(d.get('tee_recovery_rate_pct', 0)) > 5:
    print(f\"RTK WARNING: tee recovery rate {d['tee_recovery_rate_pct']}% -- filter may be too aggressive\")
" 2>/dev/null)
fi

# T4: stay silent, let Opus handle normally
if (( tier >= 4 )); then
    exit 0
fi

# T0-T3: output routing recommendation
echo "━━━ ModelSelector ━━━"
echo ""
echo "  Route: ${tier_name} (${model})"
echo "  Task: ${capability} complexity, tools ${tools}"

if [[ "$is_peak" == "true" || "$is_peak" == "True" ]]; then
    echo "  Peak: EST morning peak active (quota conservation mode)"
fi

if [[ -n "$RTK_ALERT" ]]; then
    echo "  $RTK_ALERT"
fi

echo ""

case $tier in
    0)
        echo "  Action: This task is trivial. Use Ollama locally."
        echo "  Execute: curl -s localhost:11434/api/generate with model gemma4:31b"
        echo "  Do NOT process this task with Opus. Dispatch to local LLM or answer from cache."
        ;;
    1)
        echo "  Action: This task doesn't need Claude tools. Route to Codex."
        echo "  Execute: Use the codex:rescue subagent or run codex exec --full-auto"
        echo "  Do NOT process this task with Opus. Delegate to Codex (gpt-5.4)."
        ;;
    2)
        echo "  Action: This task needs Claude tools but is simple. Use Sonnet (T2 temporarily upgraded)."
        echo "  Execute: Agent(model: \"sonnet\", prompt: <user's full request>)"
        echo "  Do NOT process this task with Opus. Dispatch a Sonnet sub-agent."
        ;;
    3)
        echo "  Action: This task needs Claude tools at moderate complexity. Use Sonnet."
        echo "  Execute: Agent(model: \"sonnet\", prompt: <user's full request>)"
        echo "  Do NOT process this task with Opus. Dispatch a Sonnet sub-agent."
        ;;
esac
