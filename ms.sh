#!/usr/bin/env bash
# ms - ModelSelector CLI Wrapper (Layer 1)
# Scores the task, picks the optimal model, and launches the right tool.
#
# Usage:
#   ms "update the readme"              # auto-routes to best model
#   ms -t opus "design auth system"     # force tier
#   ms --dry-run "some prompt"          # show what would happen
#   ms --interactive                    # enter interactive mode (launches claude)
#
# Install: source this file or add to PATH, then use `ms` command.

set -euo pipefail

MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="${MS_ROOT}/src/model-selector.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Tier colors
tier_color() {
    case "$1" in
        T0) echo -e "${GREEN}T0${NC} (Ollama gemma4:31b)" ;;
        T1) echo -e "${CYAN}T1${NC} (Codex gpt-5.4)" ;;
        T2) echo -e "${YELLOW}T2${NC} (Claude Haiku 4.5)" ;;
        T3) echo -e "${BLUE}T3${NC} (Claude Sonnet 4.6)" ;;
        T4) echo -e "${RED}T4${NC} (Claude Opus 4.6 1M)" ;;
    esac
}

# Parse args
FORCE_TIER=""
DRY_RUN=false
INTERACTIVE=false
VERBOSE=false
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
        --help|-h)
            echo "ms - ModelSelector CLI Wrapper"
            echo ""
            echo "Usage:"
            echo "  ms \"your prompt here\"        Auto-route to optimal model"
            echo "  ms -t opus \"prompt\"           Force a specific tier (T0-T4 or model name)"
            echo "  ms --dry-run \"prompt\"         Show routing without executing"
            echo "  ms -i                         Launch interactive claude (Opus)"
            echo "  ms -v \"prompt\"               Verbose output with scoring details"
            echo ""
            echo "Tier mapping:"
            echo "  T0 / ollama / local    -> Ollama gemma4:31b"
            echo "  T1 / codex / gpt       -> Codex gpt-5.4 (ChatGPT Plus)"
            echo "  T2 / haiku             -> Claude Haiku 4.5"
            echo "  T3 / sonnet            -> Claude Sonnet 4.6"
            echo "  T4 / opus              -> Claude Opus 4.6 1M"
            exit 0
            ;;
        *)
            PROMPT_ARGS+=("$1")
            shift
            ;;
    esac
done

# Interactive mode: just launch opus
if $INTERACTIVE; then
    exec claude
fi

PROMPT="${PROMPT_ARGS[*]:-}"

if [[ -z "$PROMPT" ]]; then
    echo -e "${RED}Error:${NC} No prompt provided. Use: ms \"your prompt\""
    echo "       Or: ms -i for interactive mode"
    exit 1
fi

# Score the prompt
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

# Verbose: show scoring details
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

# Dispatch to the appropriate model
case "$TIER" in
    T0)
        # Ollama: direct API call, stream to terminal
        echo -e "━━━ $(tier_color T0) ━━━"
        curl -s http://localhost:11434/api/generate \
            -d "$(python3 -c "import json; print(json.dumps({'model':'gemma4:31b','prompt':'''$PROMPT''','stream':False,'options':{'num_predict':2048}}))")" \
            2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('response','[no response]'))" 2>/dev/null
        ;;
    T1)
        # Codex: full-auto execution
        echo -e "━━━ $(tier_color T1) ━━━"
        codex exec --full-auto "$PROMPT" 2>/dev/null
        ;;
    T2)
        # Claude Sonnet (T2 temporarily routes to Sonnet instead of Haiku)
        echo -e "━━━ $(tier_color T2) ━━━"
        claude --model sonnet -p "$PROMPT"
        ;;
    T3)
        # Claude Sonnet
        echo -e "━━━ $(tier_color T3) ━━━"
        claude --model sonnet -p "$PROMPT"
        ;;
    T4)
        # Claude Opus (default)
        echo -e "━━━ $(tier_color T4) ━━━"
        claude -p "$PROMPT"
        ;;
esac
