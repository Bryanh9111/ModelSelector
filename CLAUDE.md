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

## Architecture

Dual-axis gated decision tree with static routing table. Two independent axes:
- **Axis 1: Tool Dependency** - Does the task need Claude Code native tools (Edit/Read/Agent)?
- **Axis 2: Capability** - LOW / MID / HIGH cognitive complexity

### Routing Table

| Capability | TOOLS_NONE | TOOLS_REQUIRED |
|------------|------------|----------------|
| LOW | T0 (Ollama gemma4:31b) | T2 (Haiku 4.5) |
| MID | T1 (Codex gpt-5.4) | T3 (Sonnet 4.6) |
| HIGH | T3 (Sonnet 4.6) | T4 (Opus 4.6 1M) |

### Gate Pipeline

P0 Privacy Override -> P1 Manual Override -> P2 Preprocessing (strip code fences, negation handling) -> P3 Tool Dependency Gate (regex + IS_REPO fallback) -> P4 Capability Scoring (D1 complexity + D2 domain/risk + D3 scope + D4 modifiers) -> P5 Post-routing Modifiers (hard floors, correction signal, peak hour)

### Three-Layer Integration

- **Layer 1 (CLI wrapper `ms`)**: Scores prompt BEFORE launching any model. `ms "prompt"` auto-routes to Ollama/Codex/Claude. Maximum token savings - Opus never starts for simple tasks.
- **Layer 2 (UserPromptSubmit hook)**: In-session routing. When Opus is already running, hook injects a recommendation for Claude to dispatch sub-agents at lower tiers.
- **Layer 3 (CLAUDE.md directive)**: This section. Claude reads the hook output and follows routing instructions.

## Model Tiers

| Tier | Model | Config | Cost |
|------|-------|--------|------|
| T0 | Ollama gemma4:31b | Q4_K_M, local | $0 |
| T1 | Codex gpt-5.4 | reasoning_effort=high | ChatGPT Plus subscription |
| T2 | Claude Haiku 4.5 | latest | Claude Max quota (low) |
| T3 | Claude Sonnet 4.6 | latest | Claude Max quota (mid) |
| T4 | Claude Opus 4.6 | 1M context | Claude Max quota (high) |

Key: T1 (GPT-5.4) is stronger than T2 (Haiku) and comparable to T3 (Sonnet), but lacks Claude Code tool access. T2 exists as the low-cost entry point for Claude's native tool chain.

## Project Structure

- `src/model-selector.sh` - Core scoring engine (zero LLM tokens, regex-only, EN+ZH bilingual)
- `src/hook-model-selector.sh` - UserPromptSubmit hook (Layer 2)
- `ms.sh` - CLI wrapper (Layer 1)
- `install.sh` - Installer (symlinks hooks, registers in settings.json, adds shell alias)
- `tests/test-router.sh` - Test suite (25 cases covering all tiers, gates, dampeners)
- `docs/superpowers/specs/2026-04-10-model-selector-design.md` - Full design spec

## Development

Run tests: `bash tests/test-router.sh`
Run tests verbose: `VERBOSE=1 bash tests/test-router.sh`
Test a prompt: `echo "your prompt" | src/model-selector.sh --verbose`
Test JSON output: `echo "your prompt" | src/model-selector.sh --json`
Dry-run CLI: `ms --dry-run "your prompt"`

## Design Validation

Architecture validated through 2 rounds of structured multi-model debate (Gemini 0.36, Codex gpt-5.4, Sonnet 4.6, Opus 4.6 as moderator). Key decisions: dual-axis over linear scoring, gated tree over 2D matrix, T1 ceiling at MID, IS_REPO environment fallback for ambiguous tool detection.
