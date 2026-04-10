#!/usr/bin/env bash
# ModelSelector Installer
# Installs the scoring engine, hook, and CLI wrapper.

set -euo pipefail

MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOOKS="${HOME}/.claude/hooks"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ ModelSelector Installer ━━━${NC}"
echo ""

# 1. Symlink scoring engine to hooks directory
echo -e "${GREEN}[1/4]${NC} Installing scoring engine..."
ln -sf "${MS_ROOT}/src/model-selector.sh" "${CLAUDE_HOOKS}/model-selector-engine.sh"
echo "  -> ${CLAUDE_HOOKS}/model-selector-engine.sh"

# 2. Symlink hook
echo -e "${GREEN}[2/4]${NC} Installing hook..."
ln -sf "${MS_ROOT}/src/hook-model-selector.sh" "${CLAUDE_HOOKS}/hook-model-selector.sh"
echo "  -> ${CLAUDE_HOOKS}/hook-model-selector.sh"

# 3. Add hook to settings.json if not already present
echo -e "${GREEN}[3/4]${NC} Registering hook in settings.json..."
if grep -q "hook-model-selector" "$CLAUDE_SETTINGS" 2>/dev/null; then
    echo -e "  ${YELLOW}Already registered, skipping${NC}"
else
    # Use python3 to safely modify JSON
    python3 << 'PYEOF'
import json, sys

settings_path = sys.argv[1] if len(sys.argv) > 1 else "${CLAUDE_SETTINGS}"

with open("${CLAUDE_SETTINGS}", "r") as f:
    settings = json.load(f)

# Ensure hooks.UserPromptSubmit exists
if "hooks" not in settings:
    settings["hooks"] = {}
if "UserPromptSubmit" not in settings["hooks"]:
    settings["hooks"]["UserPromptSubmit"] = []

# Check if already registered
already = any(
    any("hook-model-selector" in h.get("command", "") for h in entry.get("hooks", []))
    for entry in settings["hooks"]["UserPromptSubmit"]
)

if not already:
    # Add as FIRST hook (runs before skill-router)
    settings["hooks"]["UserPromptSubmit"].insert(0, {
        "hooks": [{
            "type": "command",
            "command": "~/.claude/hooks/hook-model-selector.sh"
        }]
    })

    with open("${CLAUDE_SETTINGS}", "w") as f:
        json.dump(settings, f, indent=2)
    print("  -> Added to UserPromptSubmit hooks (position: first)")
else:
    print("  -> Already registered")
PYEOF
fi

# 4. Add ms alias
echo -e "${GREEN}[4/4]${NC} Setting up CLI wrapper..."
MS_ALIAS="alias ms='${MS_ROOT}/ms.sh'"

# Detect shell config
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
echo -e "${GREEN}Done!${NC} ModelSelector installed."
echo ""
echo "Usage:"
echo "  ms \"your prompt\"          Auto-route to optimal model (Layer 1)"
echo "  ms -t sonnet \"prompt\"     Force a specific tier"
echo "  ms --dry-run \"prompt\"     Preview routing without executing"
echo "  ms -v \"prompt\"            Verbose: show scoring details"
echo ""
echo "The UserPromptSubmit hook (Layer 2) is active in all Claude Code sessions."
echo ""
echo -e "${YELLOW}Reload your shell:${NC} source ${SHELL_RC}"
