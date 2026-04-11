#!/usr/bin/env bash
# ModelSelector Provider Configuration
# Edit this file to map tiers to your available AI providers.
# Copy to ~/.config/model-selector/providers.sh to override.
#
# Supported providers:
#   ollama   - Local Ollama instance (free)
#   claude   - Claude Code CLI (Anthropic)
#   codex    - OpenAI Codex CLI (ChatGPT Plus)
#   amp      - Sourcegraph Amp CLI
#   openai   - OpenAI API (requires OPENAI_API_KEY)
#   gemini   - Google Gemini CLI
#   custom   - Arbitrary command (set T*_CUSTOM_CMD)

# ── Tier 0: Trivial tasks, no AI tools needed ──
T0_PROVIDER="ollama"
T0_MODEL="gemma4:31b"
T0_LABEL="Ollama gemma4:31b"

# ── Tier 1: Mid complexity, no AI-native tools needed ──
T1_PROVIDER="codex"
T1_MODEL="gpt-5.4"
T1_LABEL="Codex gpt-5.4"

# ── Tier 2: Simple tasks needing AI-native tools ──
T2_PROVIDER="claude"
T2_MODEL="sonnet"
T2_LABEL="Claude Sonnet 4.6"

# ── Tier 3: Moderate complexity with tools ──
T3_PROVIDER="claude"
T3_MODEL="sonnet"
T3_LABEL="Claude Sonnet 4.6"

# ── Tier 4: High complexity, flagship model ──
T4_PROVIDER="claude"
T4_MODEL="opus"
T4_LABEL="Claude Opus 4.6 1M"

# ── Ollama Settings ──
OLLAMA_URL="http://localhost:11434"
OLLAMA_NUM_PREDICT=2048

# ── Interactive Mode Provider ──
# Which provider to use for `ms -i` (interactive mode)
INTERACTIVE_PROVIDER="claude"
