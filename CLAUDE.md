# ModelSelector

Intelligent model routing system for Claude Code. Classifies tasks and routes to the optimal model tier.

## ModelSelector Hook Directive

When the UserPromptSubmit hook outputs "ModelSelector Route: T0/T1/T2/T3", you MUST follow the routing recommendation:

- **T0**: Do NOT process with Opus. The task is trivial. Call Ollama directly via Bash (curl localhost:11434) or answer from your existing knowledge.
- **T1**: Do NOT process with Opus. Delegate to Codex by using the codex:rescue subagent or running `codex exec --full-auto`.
- **T2**: Do NOT process with Opus. Dispatch a Haiku sub-agent: `Agent(model: "haiku", prompt: <user's full request>)`
- **T3**: Do NOT process with Opus. Dispatch a Sonnet sub-agent: `Agent(model: "sonnet", prompt: <user's full request>)`
- **T4 or no output**: Process normally with Opus. This is the correct tier.

Exception: If you determine the hook's classification is clearly wrong (e.g., a complex architecture question scored as T0), you may override with a brief explanation.

## Project Structure

- `src/model-selector.sh` - Core scoring engine (zero LLM tokens, regex-only)
- `src/hook-model-selector.sh` - UserPromptSubmit hook (Layer 2)
- `ms.sh` - CLI wrapper (Layer 1)
- `install.sh` - Installer
- `tests/` - Test suite
- `docs/superpowers/specs/` - Design spec

## Development

Run tests: `bash tests/test-router.sh`
Test a prompt: `echo "your prompt" | src/model-selector.sh --verbose`
