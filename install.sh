#!/usr/bin/env bash
# ModelSelector Installer
# Installs the scoring engine, CLI wrapper, and optionally Claude Code hook.
# Provider-agnostic: works with or without Claude.

set -euo pipefail

MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS_CONFIG_DIR="${HOME}/.config/model-selector"
MS_CONFIG="${MS_CONFIG_DIR}/providers.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ ModelSelector Installer ━━━${NC}"
echo ""

# ── Step 1: Detect available providers ──
echo -e "${GREEN}[1/5]${NC} Detecting providers..."
HAS_OLLAMA=false
HAS_CLAUDE=false
HAS_CODEX=false
HAS_AMP=false
HAS_GEMINI=false

command -v ollama &>/dev/null && HAS_OLLAMA=true
command -v claude &>/dev/null && HAS_CLAUDE=true
command -v codex &>/dev/null && HAS_CODEX=true
command -v amp &>/dev/null && HAS_AMP=true
command -v gemini &>/dev/null && HAS_GEMINI=true

$HAS_OLLAMA && echo -e "  ${GREEN}✓${NC} Ollama" || echo -e "  ${YELLOW}✗${NC} Ollama (recommended for T0)"
$HAS_CLAUDE && echo -e "  ${GREEN}✓${NC} Claude Code" || echo -e "  ${YELLOW}✗${NC} Claude Code"
$HAS_CODEX && echo -e "  ${GREEN}✓${NC} Codex" || echo -e "  ${YELLOW}✗${NC} Codex"
$HAS_AMP && echo -e "  ${GREEN}✓${NC} Amp" || echo -e "  ${YELLOW}✗${NC} Amp"
$HAS_GEMINI && echo -e "  ${GREEN}✓${NC} Gemini" || echo -e "  ${YELLOW}✗${NC} Gemini"
echo ""

# ── Step 2: Setup provider config ──
echo -e "${GREEN}[2/5]${NC} Setting up provider config..."
mkdir -p "$MS_CONFIG_DIR"

if [[ -f "$MS_CONFIG" ]]; then
    echo -e "  ${YELLOW}Config exists: ${MS_CONFIG}${NC}"
    echo "  Keeping existing config."
else
    # Auto-select best example config based on available providers
    if $HAS_CLAUDE && $HAS_CODEX; then
        cp "${MS_ROOT}/config/providers.sh" "$MS_CONFIG"
        echo "  -> Installed default config (Claude + Codex + Ollama)"
    elif ! $HAS_CLAUDE && $HAS_CODEX && $HAS_AMP; then
        cp "${MS_ROOT}/config/examples/no-claude.sh" "$MS_CONFIG"
        echo "  -> Installed no-claude config (Codex + Amp + Ollama)"
    elif ! $HAS_CLAUDE && ! $HAS_CODEX; then
        cp "${MS_ROOT}/config/examples/ollama-only.sh" "$MS_CONFIG"
        echo "  -> Installed ollama-only config (free tier)"
    else
        cp "${MS_ROOT}/config/providers.sh" "$MS_CONFIG"
        echo "  -> Installed default config"
    fi
    echo -e "  Edit: ${CYAN}${MS_CONFIG}${NC}"
    echo -e "  Examples: ${MS_ROOT}/config/examples/"
fi
echo ""

# ── Step 3: Claude Code hook (optional) ──
echo -e "${GREEN}[3/5]${NC} Claude Code integration..."
if $HAS_CLAUDE; then
    CLAUDE_HOOKS="${HOME}/.claude/hooks"
    CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
    mkdir -p "$CLAUDE_HOOKS"

    # Symlink scoring engine
    ln -sf "${MS_ROOT}/src/model-selector.sh" "${CLAUDE_HOOKS}/model-selector-engine.sh"
    echo "  -> Engine: ${CLAUDE_HOOKS}/model-selector-engine.sh"

    # Symlink hook
    ln -sf "${MS_ROOT}/src/hook-model-selector.sh" "${CLAUDE_HOOKS}/hook-model-selector.sh"
    echo "  -> Hook: ${CLAUDE_HOOKS}/hook-model-selector.sh"

    # Register hook in settings.json
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if grep -q "hook-model-selector" "$CLAUDE_SETTINGS" 2>/dev/null; then
            echo -e "  ${YELLOW}Hook already registered in settings.json${NC}"
        else
            python3 << PYEOF
import json

settings_path = "${CLAUDE_SETTINGS}"

with open(settings_path, "r") as f:
    settings = json.load(f)

if "hooks" not in settings:
    settings["hooks"] = {}
if "UserPromptSubmit" not in settings["hooks"]:
    settings["hooks"]["UserPromptSubmit"] = []

already = any(
    any("hook-model-selector" in h.get("command", "") for h in entry.get("hooks", []))
    for entry in settings["hooks"]["UserPromptSubmit"]
)

if not already:
    settings["hooks"]["UserPromptSubmit"].insert(0, {
        "hooks": [{
            "type": "command",
            "command": "~/.claude/hooks/hook-model-selector.sh"
        }]
    })

    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
    print("  -> Registered in settings.json (Layer 2 active)")
else:
    print("  -> Already registered")
PYEOF
        fi
    else
        echo -e "  ${YELLOW}No settings.json found, skipping hook registration${NC}"
    fi
else
    echo -e "  ${YELLOW}Claude not detected, skipping hook setup${NC}"
    echo "  Layer 2/3 (in-session routing) requires Claude Code."
    echo "  Layer 1 (CLI wrapper) works with any provider."
fi
echo ""

# ── Step 4: RTK integration (optional) ──
echo -e "${GREEN}[4/6]${NC} RTK (Rust Token Killer) integration..."
HAS_RTK=false
RTK_DB=""

if command -v rtk &>/dev/null; then
    HAS_RTK=true
    # Detect history.db location
    if [[ -n "${RTK_DB_PATH:-}" ]] && [[ -f "$RTK_DB_PATH" ]]; then
        RTK_DB="$RTK_DB_PATH"
    elif [[ -f "${HOME}/Library/Application Support/rtk/history.db" ]]; then
        RTK_DB="${HOME}/Library/Application Support/rtk/history.db"
    elif [[ -f "${HOME}/.local/share/rtk/history.db" ]]; then
        RTK_DB="${HOME}/.local/share/rtk/history.db"
    fi
fi

if $HAS_RTK; then
    echo -e "  ${GREEN}✓${NC} RTK detected"
    if [[ -n "$RTK_DB" ]]; then
        echo -e "  ${GREEN}✓${NC} history.db: ${RTK_DB}"
    else
        echo -e "  ${YELLOW}!${NC} history.db not found yet (RTK needs to run first)"
    fi

    # Symlink stats bridge
    ln -sf "${MS_ROOT}/src/rtk-stats.sh" "${MS_CONFIG_DIR}/rtk-stats.sh"
    echo "  -> Stats bridge: ${MS_CONFIG_DIR}/rtk-stats.sh"

    # Generate initial stats
    "${MS_ROOT}/src/rtk-stats.sh" 2>/dev/null && \
        echo -e "  ${GREEN}✓${NC} Initial stats written" || \
        echo -e "  ${YELLOW}!${NC} Stats generation skipped (no data yet)"
else
    echo -e "  ${YELLOW}✗${NC} RTK not detected (optional: install RTK for 60-90% token savings)"
    echo "  RTK compresses tool output before it reaches the LLM context."
    echo "  ModelSelector works without RTK, but combined savings are multiplicative."
fi
echo ""

# ── Step 5: Shell alias ──
echo -e "${GREEN}[5/6]${NC} Setting up CLI wrapper..."
MS_ALIAS="alias ms='${MS_ROOT}/ms.sh'"

if [[ -f "${HOME}/.zshrc" ]]; then
    SHELL_RC="${HOME}/.zshrc"
elif [[ -f "${HOME}/.bashrc" ]]; then
    SHELL_RC="${HOME}/.bashrc"
else
    SHELL_RC="${HOME}/.zshrc"
fi

if grep -q "alias ms=" "$SHELL_RC" 2>/dev/null; then
    echo -e "  ${YELLOW}Alias already exists in ${SHELL_RC}${NC}"
else
    echo "" >> "$SHELL_RC"
    echo "# ModelSelector CLI wrapper" >> "$SHELL_RC"
    echo "$MS_ALIAS" >> "$SHELL_RC"
    echo "  -> Added alias to ${SHELL_RC}"
fi
echo ""

# ── Step 6: Verify ──
echo -e "${GREEN}[6/6]${NC} Verifying installation..."
if echo "hello world" | "${MS_ROOT}/src/model-selector.sh" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Scoring engine works"
else
    echo -e "  ${RED}✗${NC} Scoring engine failed"
fi

if [[ -f "$MS_CONFIG" ]]; then
    echo -e "  ${GREEN}✓${NC} Provider config exists"
else
    echo -e "  ${RED}✗${NC} Provider config missing"
fi

echo ""
echo -e "${GREEN}Done!${NC} ModelSelector installed."
echo ""
echo "Usage:"
echo "  ms \"your prompt\"          Auto-route to optimal model"
echo "  ms -t sonnet \"prompt\"     Force a specific tier"
echo "  ms --dry-run \"prompt\"     Preview routing without executing"
echo "  ms --config               Show current provider config"
echo ""
if $HAS_CLAUDE; then
    echo "Claude Code Layer 2 hook is active in all sessions."
    echo ""
fi
echo -e "${YELLOW}Reload your shell:${NC} source ${SHELL_RC}"
