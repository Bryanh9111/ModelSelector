#!/usr/bin/env bash
# Example: No Claude subscription
# Best for: Users with Codex/Amp + local Ollama, no Anthropic account
# All tiers use free or non-Claude providers

T0_PROVIDER="ollama"
T0_MODEL="gemma4:31b"
T0_LABEL="Ollama gemma4:31b"

T1_PROVIDER="codex"
T1_MODEL="gpt-5.4"
T1_LABEL="Codex gpt-5.4"

T2_PROVIDER="amp"
T2_MODEL=""
T2_LABEL="Amp (Sourcegraph)"

T3_PROVIDER="codex"
T3_MODEL="gpt-5.4"
T3_LABEL="Codex gpt-5.4"

T4_PROVIDER="amp"
T4_MODEL=""
T4_LABEL="Amp (Sourcegraph)"

OLLAMA_URL="http://localhost:11434"
OLLAMA_NUM_PREDICT=2048
INTERACTIVE_PROVIDER="amp"
