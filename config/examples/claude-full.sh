#!/usr/bin/env bash
# Example: Full Claude setup (Anthropic Claude Max subscription)
# Best for: Users with Claude Max who want Opus for complex tasks

T0_PROVIDER="ollama"
T0_MODEL="gemma4:31b"
T0_LABEL="Ollama gemma4:31b"

T1_PROVIDER="codex"
T1_MODEL="gpt-5.4"
T1_LABEL="Codex gpt-5.4"

T2_PROVIDER="claude"
T2_MODEL="haiku"
T2_LABEL="Claude Haiku 4.5"

T3_PROVIDER="claude"
T3_MODEL="sonnet"
T3_LABEL="Claude Sonnet 4.6"

T4_PROVIDER="claude"
T4_MODEL="opus"
T4_LABEL="Claude Opus 4.6 1M"

OLLAMA_URL="http://localhost:11434"
OLLAMA_NUM_PREDICT=2048
INTERACTIVE_PROVIDER="claude"
