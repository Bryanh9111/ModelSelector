#!/usr/bin/env bash
# ModelSelector Hook - Layer 2: In-session routing
# Installed as a UserPromptSubmit hook in Claude Code settings.json
# Reads the prompt from stdin, scores it, and outputs a routing recommendation
# that Claude (Opus) reads and acts on by dispatching sub-agents.
#
# When tier < T4, output instructs Claude to delegate to a cheaper model.
# When tier = T4, output nothing (silent, let Opus handle normally).

set -euo pipefail

SELECTOR="${HOME}/.claude/hooks/model-selector-engine.sh"

# Fallback: if engine not installed at hook location, try repo location
if [[ ! -x "$SELECTOR" ]]; then
    SELECTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-selector.sh"
fi

if [[ ! -x "$SELECTOR" ]]; then
    # Engine not found, fail silently (don't break Claude Code)
    exit 0
fi

# Read prompt from stdin
PROMPT=$(cat)
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
    exit 0
fi

# Parse tier from JSON
tier=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tier'])" 2>/dev/null || echo "4")
tier_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tier_name'])" 2>/dev/null || echo "T4")
model=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['model'])" 2>/dev/null || echo "claude:opus-4.6-1m")
tools=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tools'])" 2>/dev/null || echo "REQUIRED")
capability=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['capability'])" 2>/dev/null || echo "HIGH")
is_peak=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['peak'])" 2>/dev/null || echo "false")

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
        echo "  Action: This task needs Claude tools but is simple. Use Haiku."
        echo "  Execute: Agent(model: \"haiku\", prompt: <user's full request>)"
        echo "  Do NOT process this task with Opus. Dispatch a Haiku sub-agent."
        ;;
    3)
        echo "  Action: This task needs Claude tools at moderate complexity. Use Sonnet."
        echo "  Execute: Agent(model: \"sonnet\", prompt: <user's full request>)"
        echo "  Do NOT process this task with Opus. Dispatch a Sonnet sub-agent."
        ;;
esac
