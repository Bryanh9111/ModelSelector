#!/usr/bin/env bash
# Example: OpenAI + Gemini (no Claude, no Codex CLI)
# Best for: Users with OpenAI API key and Google Gemini CLI

T0_PROVIDER="ollama"
T0_MODEL="gemma4:31b"
T0_LABEL="Ollama gemma4:31b"

T1_PROVIDER="openai"
T1_MODEL="gpt-4o"
T1_LABEL="OpenAI gpt-4o"

T2_PROVIDER="gemini"
T2_MODEL=""
T2_LABEL="Gemini CLI"

T3_PROVIDER="openai"
T3_MODEL="gpt-4o"
T3_LABEL="OpenAI gpt-4o"

T4_PROVIDER="gemini"
T4_MODEL=""
T4_LABEL="Gemini CLI"

OLLAMA_URL="http://localhost:11434"
OLLAMA_NUM_PREDICT=2048
INTERACTIVE_PROVIDER="gemini"
