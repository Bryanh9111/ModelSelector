#!/usr/bin/env bash
# ms - ModelSelector CLI Wrapper (Layer 1)
# Scores the task, picks the optimal model, and dispatches to the right provider.
# Provider-agnostic: configure providers in config/providers.sh
#
# Usage:
#   ms "update the readme"              # auto-routes to best model
#   ms -t opus "design auth system"     # force tier
#   ms --dry-run "some prompt"          # show what would happen
#   ms --interactive                    # enter interactive mode
#   ms --config                         # show current provider config
#
# Install: bash install.sh

set -euo pipefail

MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="${MS_ROOT}/src/model-selector.sh"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Load provider config ──
# Priority: ~/.config/model-selector/providers.sh > repo config/providers.sh
MS_CONFIG="${HOME}/.config/model-selector/providers.sh"
if [[ ! -f "$MS_CONFIG" ]]; then
    MS_CONFIG="${MS_ROOT}/config/providers.sh"
fi
if [[ ! -f "$MS_CONFIG" ]]; then
    echo -e "${RED}Error:${NC} No provider config found."
    echo "  Run: bash install.sh"
    exit 1
fi
source "$MS_CONFIG"

# ── Provider dispatch functions ──

dispatch_ollama() {
    local model="$1" prompt="$2"
    local url="${OLLAMA_URL:-http://localhost:11434}"
    local max_tokens="${OLLAMA_NUM_PREDICT:-2048}"

    if ! curl -s --connect-timeout 2 "${url}/api/tags" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Ollama not running at ${url}"
        echo "  Start it: ollama serve"
        return 1
    fi

    curl -s "${url}/api/generate" \
        -d "$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({'model':'$model','prompt':prompt,'stream':False,'options':{'num_predict':$max_tokens}}))" <<< "$prompt")" \
        2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('response','[no response]'))" 2>/dev/null
}

dispatch_claude() {
    local model="$1" prompt="$2"
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}Error:${NC} Claude CLI not installed."
        echo "  Install: npm install -g @anthropic-ai/claude-code"
        return 1
    fi
    if [[ "$model" == "opus" ]]; then
        claude -p "$prompt"
    else
        claude --model "$model" -p "$prompt"
    fi
}

dispatch_codex() {
    local model="$1" prompt="$2"
    if ! command -v codex &>/dev/null; then
        echo -e "${RED}Error:${NC} Codex CLI not installed."
        echo "  Install: npm install -g @openai/codex"
        return 1
    fi
    codex exec --full-auto "$prompt" 2>/dev/null
}

dispatch_amp() {
    local model="$1" prompt="$2"
    if ! command -v amp &>/dev/null; then
        echo -e "${RED}Error:${NC} Amp CLI not installed."
        echo "  Install: https://sourcegraph.com/docs/amp"
        return 1
    fi
    amp "$prompt"
}

dispatch_openai() {
    local model="$1" prompt="$2"
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo -e "${RED}Error:${NC} OPENAI_API_KEY not set."
        return 1
    fi
    curl -s https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({'model':'$model','messages':[{'role':'user','content':prompt}],'max_tokens':2048}))" <<< "$prompt")" \
        2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null
}

dispatch_gemini() {
    local model="$1" prompt="$2"
    if ! command -v gemini &>/dev/null; then
        echo -e "${RED}Error:${NC} Gemini CLI not installed."
        echo "  Install: npm install -g @anthropic-ai/claude-code (Gemini plugin)"
        return 1
    fi
    gemini "$prompt"
}

dispatch_custom() {
    local model="$1" prompt="$2" tier="$3"
    local cmd_var="T${tier}_CUSTOM_CMD"
    local cmd="${!cmd_var:-}"
    if [[ -z "$cmd" ]]; then
        echo -e "${RED}Error:${NC} Custom provider requires ${cmd_var} in config."
        return 1
    fi
    # SECURITY: $cmd comes from providers.sh which the user controls.
    # Since providers.sh is already sourced (trusted), eval is acceptable here.
    # If you set a custom command, make sure it handles prompts via stdin.
    eval "$cmd" <<< "$prompt"
}

# ── Dispatch router ──
dispatch() {
    local tier="$1" prompt="$2"
    local provider_var="T${tier}_PROVIDER"
    local model_var="T${tier}_MODEL"
    local provider="${!provider_var:-}"
    local model="${!model_var:-}"

    case "$provider" in
        ollama)  dispatch_ollama "$model" "$prompt" ;;
        claude)  dispatch_claude "$model" "$prompt" ;;
        codex)   dispatch_codex "$model" "$prompt" ;;
        amp)     dispatch_amp "$model" "$prompt" ;;
        openai)  dispatch_openai "$model" "$prompt" ;;
        gemini)  dispatch_gemini "$model" "$prompt" ;;
        custom)  dispatch_custom "$model" "$prompt" "${tier}" ;;
        *)
            echo -e "${RED}Error:${NC} Unknown provider: $provider"
            return 1
            ;;
    esac
}

# ── Tier display ──
tier_color() {
    local tier="$1"
    local label_var="T${tier#T}_LABEL"
    local label="${!label_var:-unknown}"
    case "$tier" in
        T0) echo -e "${GREEN}T0${NC} ($label)" ;;
        T1) echo -e "${CYAN}T1${NC} ($label)" ;;
        T2) echo -e "${YELLOW}T2${NC} ($label)" ;;
        T3) echo -e "${BLUE}T3${NC} ($label)" ;;
        T4) echo -e "${RED}T4${NC} ($label)" ;;
    esac
}

# ── Parse args ──
FORCE_TIER=""
DRY_RUN=false
INTERACTIVE=false
VERBOSE=false
SHOW_CONFIG=false
SHOW_STATS=false
PROMPT_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tier)
            FORCE_TIER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --interactive|-i)
            INTERACTIVE=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --config)
            SHOW_CONFIG=true
            shift
            ;;
        --stats)
            SHOW_STATS=true
            shift
            ;;
        --help|-h)
            echo "ms - ModelSelector CLI Wrapper"
            echo ""
            echo "Usage:"
            echo "  ms \"your prompt here\"        Auto-route to optimal model"
            echo "  ms -t opus \"prompt\"           Force a specific tier"
            echo "  ms --dry-run \"prompt\"         Show routing without executing"
            echo "  ms -i                         Launch interactive mode"
            echo "  ms -v \"prompt\"               Verbose output with scoring details"
            echo "  ms --config                   Show current provider configuration"
            echo "  ms --stats                    Unified ROI dashboard (routing + RTK)"
            echo ""
            echo "Tier aliases:"
            echo "  T0 / ollama / local"
            echo "  T1 / codex / gpt"
            echo "  T2 / haiku"
            echo "  T3 / sonnet"
            echo "  T4 / opus"
            echo ""
            echo "Config: ${MS_CONFIG}"
            exit 0
            ;;
        *)
            PROMPT_ARGS+=("$1")
            shift
            ;;
    esac
done

# Show config
if $SHOW_CONFIG; then
    echo -e "━━━ ${CYAN}ModelSelector Config${NC} ━━━"
    echo -e "  Config: ${MS_CONFIG}"
    echo ""
    for t in 0 1 2 3 4; do
        echo -e "  $(tier_color "T${t}")"
        local_provider="T${t}_PROVIDER"
        echo -e "    Provider: ${!local_provider:-not set}"
    done
    echo ""
    echo -e "  Examples: ${MS_ROOT}/config/examples/"
    exit 0
fi

# Show unified stats dashboard
if $SHOW_STATS; then
    echo -e "━━━ ${CYAN}ModelSelector + RTK Stats${NC} ━━━"
    echo ""

    # Refresh RTK stats
    RTK_STATS_BRIDGE="${MS_ROOT}/src/rtk-stats.sh"
    if [[ -x "$RTK_STATS_BRIDGE" ]]; then
        "$RTK_STATS_BRIDGE" 2>/dev/null
    fi

    RTK_STATS="${HOME}/.config/model-selector/rtk-stats.json"
    MS_LOG="${HOME}/.claude/model-selector.log"

    # ModelSelector routing history (from log)
    echo -e "  ${BOLD}ModelSelector Routing${NC}"
    if [[ -f "$MS_LOG" ]]; then
        total_routes=$(wc -l < "$MS_LOG" | tr -d ' ')
        t0_count=$(grep -c ' T0 ' "$MS_LOG" 2>/dev/null || echo 0)
        t1_count=$(grep -c ' T1 ' "$MS_LOG" 2>/dev/null || echo 0)
        t2_count=$(grep -c ' T2 ' "$MS_LOG" 2>/dev/null || echo 0)
        t3_count=$(grep -c ' T3 ' "$MS_LOG" 2>/dev/null || echo 0)
        t4_count=$(grep -c ' T4 ' "$MS_LOG" 2>/dev/null || echo 0)
        echo "    Total routes: $total_routes"
        echo -e "    ${GREEN}T0${NC}: $t0_count | ${CYAN}T1${NC}: $t1_count | ${YELLOW}T2${NC}: $t2_count | ${BLUE}T3${NC}: $t3_count | ${RED}T4${NC}: $t4_count"

        # Calculate savings estimate (routes NOT sent to Opus)
        saved_routes=$(( t0_count + t1_count + t2_count + t3_count ))
        if (( total_routes > 0 )); then
            pct=$(python3 -c "print(round($saved_routes / $total_routes * 100, 1))" 2>/dev/null || echo "?")
            echo "    Opus avoided: ${saved_routes}/${total_routes} (${pct}%)"
        fi

        # Correction rate analysis
        corr_total=$(grep -c 'corr=true' "$MS_LOG" 2>/dev/null || echo 0)
        if (( total_routes > 0 && corr_total > 0 )); then
            corr_pct=$(python3 -c "print(round($corr_total / $total_routes * 100, 1))" 2>/dev/null || echo "?")
            echo "    Correction signals: ${corr_total}/${total_routes} (${corr_pct}%)"
            for t in T0 T1 T2 T3 T4; do
                tier_total=$(grep -c " $t " "$MS_LOG" 2>/dev/null || true); tier_total=${tier_total:-0}
                tier_corr=$(grep " $t " "$MS_LOG" 2>/dev/null | grep -c 'corr=true' 2>/dev/null || true); tier_corr=${tier_corr:-0}
                if (( tier_corr > 0 )); then
                    tier_pct=$(python3 -c "print(round($tier_corr / $tier_total * 100, 1))" 2>/dev/null || echo "?")
                    echo "      ${t}: ${tier_corr}/${tier_total} (${tier_pct}%)"
                fi
            done
        fi
    else
        echo "    No routing history yet."
    fi
    echo ""

    # RTK compression stats
    echo -e "  ${BOLD}RTK Token Compression${NC}"
    if [[ -f "$RTK_STATS" ]]; then
        python3 -c "
import json
d = json.load(open('$RTK_STATS'))
if not d.get('rtk_active'):
    print('    RTK not active (no history.db found)')
else:
    print(f\"    7-day avg savings: {d.get('avg_savings_pct', 0)}%\")
    print(f\"    7-day commands: {d.get('total_records_7d', 0)}\")
    avg_in = d.get('avg_input_tokens', 0)
    avg_out = d.get('avg_output_tokens', 0)
    print(f\"    Avg: {avg_in} -> {avg_out} tokens/command\")
    print(f\"    Tee recovery rate: {d.get('tee_recovery_rate_pct', 0)}%\")
    lt = d.get('lifetime_saved_tokens', 0)
    lr = d.get('lifetime_records', 0)
    print(f\"    Lifetime: {lt:,} tokens saved across {lr:,} commands\")
    sr = d.get('session_records_1h', 0)
    st = d.get('session_saved_tokens', 0)
    print(f\"    Session (1h): {sr} commands, {st:,} tokens saved\")
" 2>/dev/null
    else
        echo "    No RTK stats. Run: src/rtk-stats.sh --verbose"
    fi
    echo ""

    # Combined ROI estimate
    echo -e "  ${BOLD}Combined ROI${NC}"
    if [[ -f "$MS_LOG" ]] && [[ -f "$RTK_STATS" ]]; then
        python3 -c "
import json

stats = json.load(open('$RTK_STATS'))
lifetime_saved = stats.get('lifetime_saved_tokens', 0)
active = stats.get('rtk_active', False)

# Rough cost model for Claude Max (quota-based, not dollar-based)
# Express savings as 'Opus-equivalent tokens avoided'
# T0/T1 dispatch saves ~all Opus tokens for that prompt
# RTK saves input tokens that would have been in Opus context

print('    Optimization layers:')
print('      Layer 1 (ModelSelector): routes cheap tasks away from Opus')
print('      Layer 2 (RTK): compresses tool output for all tiers')
if active:
    print(f\"      Combined: routing + {lifetime_saved:,} tokens compressed\")
    rate = float(stats.get('tee_recovery_rate_pct', 0))
    if rate > 5:
        print(f\"      WARNING: tee recovery {rate}% -- consider relaxing RTK filters\")
    elif rate > 0:
        print(f\"      Quality: tee recovery {rate}% (healthy)\")
    else:
        print(f\"      Quality: no parse failures (excellent)\")
else:
    print('      RTK not active -- install RTK for 60-90% additional savings')
" 2>/dev/null
    fi
    echo ""
    exit 0
fi

# Interactive mode
if $INTERACTIVE; then
    case "${INTERACTIVE_PROVIDER:-claude}" in
        claude) exec claude ;;
        amp)    exec amp ;;
        gemini) exec gemini ;;
        codex)  exec codex ;;
        *)      exec "${INTERACTIVE_PROVIDER}" ;;
    esac
fi

PROMPT="${PROMPT_ARGS[*]:-}"

if [[ -z "$PROMPT" ]]; then
    echo -e "${RED}Error:${NC} No prompt provided. Use: ms \"your prompt\""
    echo "       Or: ms -i for interactive mode"
    exit 1
fi

# ── Score the prompt ──
if [[ -n "$FORCE_TIER" ]]; then
    case "$FORCE_TIER" in
        T0|t0|ollama|local)  TIER="T0" ;;
        T1|t1|codex|gpt)     TIER="T1" ;;
        T2|t2|haiku)         TIER="T2" ;;
        T3|t3|sonnet)        TIER="T3" ;;
        T4|t4|opus)          TIER="T4" ;;
        *)
            echo -e "${RED}Error:${NC} Unknown tier: $FORCE_TIER"
            exit 1
            ;;
    esac
else
    TIER=$(echo "$PROMPT" | "$SELECTOR")
fi

# Verbose / dry-run output
if $VERBOSE || $DRY_RUN; then
    echo -e "━━━ ${CYAN}ModelSelector${NC} ━━━"
    echo -e "  Route: $(tier_color "$TIER")"
    if [[ -z "$FORCE_TIER" ]]; then
        echo "$PROMPT" | "$SELECTOR" --verbose 2>/dev/null | grep -E '^\s+(Score|Reasons|Peak|-)' || true
    else
        echo "  Reason: Manual override -> $FORCE_TIER"
    fi
    echo ""
fi

if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${NC} Would execute with $(tier_color "$TIER")"
    exit 0
fi

# ── Dispatch ──
TIER_NUM="${TIER#T}"
echo -e "━━━ $(tier_color "$TIER") ━━━"
dispatch "$TIER_NUM" "$PROMPT"
