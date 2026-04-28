# ModelSelector

> ## ARCHIVED 2026-04-28
>
> **Experimental result: the auto-routing hypothesis was wrong.**
>
> In-session auto-routing (Layer 2 `UserPromptSubmit` hook + Layer 3 `CLAUDE.md` directive) was supposed to save tokens by dispatching simple tasks to cheaper models. In practice it **increased** total token consumption:
>
> - Cold-start sub-agent dispatch requires packing the full context into the sub-agent's prompt (no session memory inheritance)
> - Sub-agent results have to be relayed back to the orchestrator and often re-explained to the user
> - Combined cost: **5-20x more tokens** than letting the orchestrator answer directly
> - Anthropic prompt cache (input cost ~1/10 with cache hit) and [RTK](https://github.com/rtk-ai/rtk) (60-93% tool output compression) already capture the meaningful savings without these failure modes
>
> **Status of components:**
> - Layer 2 (UserPromptSubmit hook) -- **decommissioned** (removed from `~/.claude/settings.json`)
> - Layer 3 (CLAUDE.md routing directive) -- **inert** without Layer 2 output
> - Layer 1 (`ms` CLI wrapper) -- **functional but unused in practice**
> - Scoring engine (`src/model-selector.sh`) -- preserved as a reference for keyword-based prompt classification
>
> `install.sh` now aborts unless `MS_FORCE_INSTALL=1` is set. Repository kept as a design study and warning to anyone tempted by the same hypothesis.
>
> **Active replacements:** RTK for tool output compression + Anthropic prompt cache for input compression. No model-selection layer needed.

---

**ModelSelector** is an open-source model routing system for AI coding assistants that automatically picks the cheapest capable model for each task. It scores prompts locally using pure regex pattern matching (zero LLM tokens, <10ms), classifies tasks on two axes (tool dependency and cognitive complexity), and dispatches to the optimal tier from free local models to flagship APIs.

In production use, ModelSelector routes 69% of tasks away from expensive flagship models with a 0.3% misroute rate, cutting AI coding costs without sacrificing quality on complex tasks.

**Provider-agnostic.** Works with Claude, Codex/GPT, Amp, Gemini, OpenAI API, Ollama, or any combination. No vendor lock-in.

## How It Works

```
You type: ms "update the readme"

ModelSelector scoring engine (pure bash, 0 tokens):
  - Axis 1: Does this need AI-native tools? (Edit/Read/Agent)
  - Axis 2: How complex is this? (LOW / MID / HIGH)

Routing table:
  | Capability | No Tools | Tools Required |
  |------------|----------|----------------|
  | LOW        | T0 (free)| T2 (cheap)     |
  | MID        | T1 (mid) | T3 (strong)    |
  | HIGH       | T3 (strong)| T4 (flagship)|

Result: T0 -> dispatches to Ollama (free, local)
```

Simple tasks never touch expensive models. Complex tasks get the firepower they need. Unlike token-level compression or prompt caching, ModelSelector saves costs at the model selection layer -- the most expensive decision in the AI coding stack.

**RTK integration.** Optionally pairs with [RTK (Rust Token Killer)](https://github.com/rtk-ai/rtk) for multiplicative savings: ModelSelector picks the cheapest model (model-level savings), RTK compresses tool output 60-93% (token-level savings). Combined: cheaper model x fewer tokens.

## How It Compares

| Approach | Layer | Saves on | Needs API call? | Works with any model? |
|----------|-------|----------|-----------------|----------------------|
| **ModelSelector** | Model selection | Model cost (use cheaper model) | No (local regex) | Yes (7 providers) |
| Prompt caching | Token pricing | Per-token cost (reuse prefix) | Yes (provider feature) | No (provider-specific) |
| RTK / compression | Token count | Input tokens (compress output) | No (local rewrite) | Yes |
| Shorter prompts | Token count | Input tokens (manual editing) | No | Yes |
| Rate limiting | Usage cap | Overspend prevention | No | Yes |

ModelSelector is the only approach that operates at the model selection layer. It composes with all other approaches for multiplicative savings.

## Quick Start

### Prerequisites

- macOS or Linux with bash 4+
- Python 3 (for JSON parsing)
- At least one AI provider installed (see Provider Setup below)

### Install

```bash
git clone https://github.com/Bryanh9111/ModelSelector.git
cd ModelSelector
bash install.sh
source ~/.zshrc  # or ~/.bashrc
```

The installer will:
1. Detect available providers (Ollama, Claude, Codex, Amp, Gemini)
2. Generate a provider config at `~/.config/model-selector/providers.sh`
3. Symlink the scoring engine and hook to `~/.claude/hooks/` (if Claude is available)
4. Detect RTK and configure the data bridge (if installed)
5. Add the `ms` alias to your shell

### First Run

```bash
# Auto-route to the best model for the task
ms "explain what a closure is in javascript"

# See what model would be picked (without executing)
ms --dry-run "refactor this authentication module"

# Show your current provider configuration
ms --config
```

## Provider Setup

ModelSelector supports 7 provider types. You only need the ones you have.

### Ollama (Local, Free)

The backbone of T0. Runs models locally at zero cost.

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model (recommended for T0)
ollama pull gemma4:31b     # 18.5GB - best all-around for 48GB+ RAM
ollama pull gemma3:12b     # 7GB   - for 16GB RAM machines

# Start the server
ollama serve
```

**RAM Guide:**

| Your RAM | Recommended Model | Quantization | Size |
|----------|------------------|-------------|------|
| 8GB | gemma3:4b | default | ~2.5GB |
| 16GB | gemma3:12b | default | ~7GB |
| 32GB | gemma4:31b | Q4_K_M | ~19GB |
| 48GB | gemma4:31b | Q4_K_M | ~19GB |
| 64GB | gemma4:31b-it-q8_0 | Q8 | ~33GB |
| 128GB+ | gemma4:31b (FP16) | Full precision | ~62GB |

**Qwen alternative** (stronger reasoning, but thinking models may consume output budget via Ollama):

| Your RAM | Recommended Model | Quantization | Size |
|----------|------------------|-------------|------|
| 16GB | qwen3:8b | Q4_K_M | ~5GB |
| 32GB | qwen3:32b | Q4_K_M | ~20GB |
| 48GB | qwen3.5:35b | Q4_K_M | ~23GB |
| 64GB | qwen3:32b-q8_0 | Q8 | ~34GB |
| 128GB+ | qwen3:72b | Q4_K_M | ~42GB |

> **Why gemma4 is the default:** In our [local model benchmark](docs/local-model-benchmark.md), gemma4:31b achieved 100% task completion while all Qwen thinking models scored 33-50% due to the "thinking token black hole" -- internal reasoning consumes the output token budget via Ollama's generate API. Use Qwen if you disable thinking (`-nothink` variants) or use the chat API.

> **Q4 vs Q8 on 48GB RAM:** We benchmarked both on a 48GB Mac across 5 tasks (code gen, math, Chinese, long-form, JSON). Q8 is **2.6x slower** (~34 tok/s vs ~89 tok/s) because the 33GB model causes memory pressure and swap. Quality difference is negligible. Q8 only makes sense on 64GB+ where the model fits comfortably in RAM.

### Claude Code CLI (Anthropic)

For T2/T3/T4. Requires a Claude subscription (Pro or Max).

```bash
# Install
npm install -g @anthropic-ai/claude-code

# Verify
claude --version
```

### Codex CLI (OpenAI)

For T1. Requires ChatGPT Plus subscription.

```bash
# Install
npm install -g @openai/codex

# Verify
codex --version
```

### Amp (Sourcegraph)

Alternative to Claude for tool-using tiers.

```bash
# Install - see https://sourcegraph.com/docs/amp
# Verify
amp --version
```

### OpenAI API (Direct)

Use GPT models via API. Requires `OPENAI_API_KEY`.

```bash
export OPENAI_API_KEY="sk-..."
```

### Gemini CLI (Google)

```bash
# Install
npm install -g @anthropic-ai/claude-code  # with Gemini plugin
# Or standalone Gemini CLI
```

### Custom Provider

For any CLI tool not listed above:

```bash
# In your providers.sh:
T3_PROVIDER="custom"
T3_CUSTOM_CMD="my-ai-tool --prompt"
```

## Configuration

### Provider Config File

The config lives at `~/.config/model-selector/providers.sh` (falls back to `config/providers.sh` in the repo).

```bash
# View current config
ms --config

# Edit config
nano ~/.config/model-selector/providers.sh
```

### Example Configurations

Pre-built configs are in `config/examples/`. Copy one to get started:

```bash
# Full Claude setup (Claude Max subscription)
cp config/examples/claude-full.sh ~/.config/model-selector/providers.sh

# No Claude - Codex + Amp + Ollama
cp config/examples/no-claude.sh ~/.config/model-selector/providers.sh

# Ollama only (completely free)
cp config/examples/ollama-only.sh ~/.config/model-selector/providers.sh

# OpenAI API + Gemini
cp config/examples/openai-gemini.sh ~/.config/model-selector/providers.sh
```

### Config Format

```bash
# Each tier has three variables:
T0_PROVIDER="ollama"        # Provider type (ollama/claude/codex/amp/openai/gemini/custom)
T0_MODEL="gemma4:31b"       # Model name (provider-specific)
T0_LABEL="Ollama gemma4:31b"  # Display label

# Ollama settings
OLLAMA_URL="http://localhost:11434"
OLLAMA_NUM_PREDICT=2048

# Interactive mode provider (ms -i)
INTERACTIVE_PROVIDER="claude"
```

## Usage

### Basic Commands

```bash
# Auto-route (the main use case)
ms "your prompt here"

# Force a specific tier
ms -t ollama "simple question"
ms -t codex "analyze this code"
ms -t sonnet "refactor auth module"
ms -t opus "design microservice architecture"

# Dry run - see routing without executing
ms --dry-run "some task"

# Verbose - see scoring details
ms -v "complex task"

# Interactive mode - launches your configured interactive provider
ms -i

# Show config
ms --config

# Unified dashboard (routing + RTK compression + ROI)
ms --stats
```

### Tier Aliases

| Alias | Maps to |
|-------|---------|
| `T0` / `t0` / `ollama` / `local` | Tier 0 |
| `T1` / `t1` / `codex` / `gpt` | Tier 1 |
| `T2` / `t2` / `haiku` | Tier 2 |
| `T3` / `t3` / `sonnet` | Tier 3 |
| `T4` / `t4` / `opus` | Tier 4 |

### Test the Scoring Engine Directly

The scoring engine works independently of any provider:

```bash
# Score a prompt (returns tier)
echo "update the readme" | src/model-selector.sh

# Verbose scoring
echo "design a distributed auth system" | src/model-selector.sh --verbose

# JSON output
echo "fix this typo" | src/model-selector.sh --json
```

## Architecture

### Three-Layer Integration

```
Layer 1: CLI Wrapper (ms)
  Scores prompt BEFORE any model starts.
  Routes to the cheapest capable provider.
  Maximum savings - expensive models never start for simple tasks.

Layer 2: UserPromptSubmit Hook (Claude Code only)
  When an expensive model is already running,
  recommends dispatching to a cheaper sub-agent.
  Savings limited by model already being active.

Layer 3: CLAUDE.md Directive (Claude Code only)
  Instructions for Claude to follow hook recommendations.
  The "brain" that reads Layer 2 output and acts on it.
```

**Layer 1 is provider-agnostic.** Layers 2 and 3 are Claude Code-specific.

### Scoring Engine

Dual-axis gated decision tree. Pure regex, zero LLM tokens, runs in <10ms:

- **P0**: Privacy override (sensitive data stays local)
- **P1**: Manual override (`-t` flag)
- **P2**: Preprocessing (strip code fences, handle negation)
- **P3**: Tool dependency gate (regex + IS_REPO fallback)
- **P4**: Capability scoring (complexity + domain + scope + modifiers)
- **P5**: Post-routing (hard floors, correction signal, peak hours)
- **P6**: RTK integration (compression bonus, quality gate)

Supports English and Chinese prompts.

## RTK Integration (Optional)

[RTK (Rust Token Killer)](https://github.com/rtk-ai/rtk) compresses CLI command output before it reaches the LLM context. When paired with ModelSelector, the savings are multiplicative: cheaper model x fewer tokens.

### Setup

```bash
# 1. Install Rust (if not already)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 2. Install RTK
git clone https://github.com/rtk-ai/rtk.git
cd rtk && cargo install --path .

# 3. Register RTK hook for Claude Code
rtk init -g

# 4. Re-run ModelSelector installer (detects RTK automatically)
cd /path/to/ModelSelector && bash install.sh
```

The installer detects RTK, symlinks the stats bridge, and generates initial stats. No further configuration needed.

### How It Works Together

```
Your prompt
  -> [ModelSelector] scores prompt, picks cheapest capable model (T0-T4)
  -> Model runs, needs to execute commands:
     -> [RTK] auto-rewrites: git status -> rtk git status
     -> Output compressed 60-90% before reaching LLM context
  -> [P6] RTK compression history feeds back into routing decisions
```

ModelSelector adjusts RTK's compression aggressiveness per tier:
- T0 (8K context): aggressive compression (show less, fit more)
- T4 (1M context): relaxed compression (let model see more)

### Dashboard

```bash
# Unified ROI: routing stats + compression stats + combined savings
ms --stats

# RTK standalone stats
rtk gain
rtk gain --history
```

## Local Model Benchmark

We benchmarked 5 local models on 6 dimensions (code gen, bug finding, reasoning, Chinese, JSON, refactoring). Key findings:

| Model | Type | tok/s | Completion Rate |
|-------|------|-------|----------------|
| gemma4:31b | dense | ~11 | **6/6 (100%)** |
| qwen3:32b | dense+thinking | ~12 | 3/6 (50%) |
| deepseek-r1:32b | dense+thinking | ~12 | 2/6 (33%) |
| qwen3.5:35b | MoE+thinking | ~30 | 3/6 (50%) |

**gemma4:31b is the only model with 100% reliability.** All thinking models suffer from a "thinking token black hole" where internal reasoning consumes the output token budget via Ollama's generate API.

Full report: [docs/local-model-benchmark.md](docs/local-model-benchmark.md)

## Development

```bash
# Run test suite (29 cases)
bash tests/test-router.sh

# Verbose tests
VERBOSE=1 bash tests/test-router.sh

# Run local model benchmark
python3 tests/local-model-bench.py

# Test a specific prompt
echo "your prompt" | src/model-selector.sh --verbose
```

## Project Structure

```
ModelSelector/
  ms.sh                          # CLI wrapper (Layer 1) - provider-agnostic
  install.sh                     # Installer (auto-detects providers + RTK)
  config/
    providers.sh                 # Default provider config
    examples/
      claude-full.sh             # Full Claude setup
      no-claude.sh               # Codex + Amp + Ollama
      ollama-only.sh             # Free tier only
      openai-gemini.sh           # OpenAI API + Gemini
  src/
    model-selector.sh            # Scoring engine (P0-P6, pure regex)
    hook-model-selector.sh       # Claude Code hook (Layer 2)
    rtk-stats.sh                 # RTK data bridge + manual --adapt-limits CLI
  tests/
    test-router.sh               # Test suite (29 cases)
    local-model-bench.py         # Local model benchmark
  docs/
    local-model-benchmark.md     # Benchmark report
    debates/                     # Architecture decision records
```

## Real-World Performance

Production metrics after 5 days of daily-driver use (single developer, mixed EN/ZH prompts):

### Model Routing

| Metric | Value |
|--------|-------|
| Total routes | 583 |
| **Opus avoided** | **69.4%** (404/583) |
| Correction signals | 0.3% (2/583) |

Tier distribution:

| T0 (free) | T1 (Codex) | T2 (Haiku) | T3 (Sonnet) | T4 (Opus) |
|-----------|------------|------------|-------------|-----------|
| 48 (8%) | 52 (9%) | 213 (37%) | 91 (16%) | 6 (1%) |

T2 dominates because most in-session tasks are simple tool operations (rename, read, small edits). T4 fires only for complex architecture and multi-file refactors.

### RTK Compression (when paired)

| Metric | Value |
|--------|-------|
| Commands compressed | 589 |
| Total tokens saved | 1.34M (93.4%) |
| Avg per command | 2,441 -> 162 tokens |
| Top saver | `read` (101 calls, 681K tokens saved) |

### Combined ROI

ModelSelector picks the cheapest model (69% of tasks skip Opus). RTK compresses what the model sees (93% token reduction on tool output). Together: cheaper model x fewer tokens.

## FAQ

**Q: Do I need Claude to use this?**
No. The scoring engine and Layer 1 CLI are provider-agnostic. Configure `config/providers.sh` to use whatever AI providers you have. See `config/examples/no-claude.sh` or `config/examples/ollama-only.sh`.

**Q: Can I use this with only free/local models?**
Yes. Copy `config/examples/ollama-only.sh` to your config. All tiers route to local Ollama. Zero cost.

**Q: How does scoring work without calling an LLM?**
Pure regex pattern matching on the prompt text. The engine checks for tool-related keywords (edit, file, git), complexity signals (architecture, design, system), domain markers (security, auth), and scope indicators (refactor, multiple files). No LLM call, runs in <10ms.

**Q: My prompt is being misrouted. What do I do?**
Use `ms -v "your prompt"` to see the scoring breakdown. If a specific pattern needs adjustment, the thresholds are in `src/model-selector.sh`. You can also force a tier with `ms -t sonnet "your prompt"`.

**Q: Can I add my own AI provider?**
Yes. Set `T*_PROVIDER="custom"` and `T*_CUSTOM_CMD="your-command"` in your providers.sh. The command receives the prompt via stdin.

**Q: Why does Layer 2 use Agent dispatch instead of `/model` switching?**
Claude Code's `/model` command switches the entire session to a different model but keeps the full conversation history. Agent dispatch spawns an isolated sub-agent with only a brief prompt. For Layer 2's per-message routing, dispatch wins on every axis:

| | `/model` switch | Agent dispatch |
|--|-----------------|----------------|
| Input tokens | Full history (10K-100K+) | Brief prompt (~200-500) |
| Scope | All subsequent messages | Single task |
| Automation | Manual only | Hook/CLAUDE.md driven |
| Risk | Forget to switch back | None (auto-returns) |
| Orchestration | Cheap model decides | Opus stays in control |

**Q: What about the Anthropic Advisor Tool?**
The Advisor Tool (beta, April 2026) lets Sonnet consult Opus on hard decisions. When Claude Code CLI supports `--advisor`, ModelSelector's T3/T4 tiers can merge. We're tracking this for a future update.

**Q: How much does ModelSelector save on AI coding costs?**
In 5 days of production use (583 routed tasks), ModelSelector avoided the flagship model (Opus) for 69.4% of tasks. Combined with RTK token compression (93.4% reduction, 1.34M tokens saved), the effective cost reduction is multiplicative: most tasks use a model 10-50x cheaper AND see 60-93% fewer input tokens. Exact dollar savings depend on your pricing plan and task mix.

**Q: How does ModelSelector compare to prompt caching or context compression?**
They solve different layers of the cost stack and work together, not as alternatives. Prompt caching (Anthropic, OpenAI) reduces per-token cost by reusing prefixes. Context compression (RTK, summary tools) reduces token count. ModelSelector reduces model cost by routing simple tasks to cheaper models. The savings multiply: cheap model x cached tokens x compressed context.

**Q: Does ModelSelector work with Claude Code / Cursor / Windsurf / Cline?**
ModelSelector integrates natively with Claude Code via UserPromptSubmit hooks (Layer 2) and CLAUDE.md directives (Layer 3). The Layer 1 CLI (`ms`) is standalone and works with any AI coding tool that accepts prompts via CLI. Cursor, Windsurf, and Cline integration would require their respective hook/plugin systems.

**Q: Can ModelSelector handle non-English prompts?**
Yes. The scoring engine includes bilingual pattern matching for English and Chinese (Simplified) prompts. Keywords like "重构" (refactor), "安全" (security), and "架构" (architecture) are scored alongside their English equivalents. Adding more languages requires extending the regex patterns in `src/model-selector.sh`.

**Q: Is this just keyword matching? How accurate is it?**
Yes, it is pure keyword/regex matching -- and that is a feature, not a limitation. The engine runs in <10ms with zero API calls. After threshold calibration on real prompts, the misroute rate is 0.3% (2 corrections out of 583 routes). When misrouting does occur, the correction signal system automatically escalates the tier for the next similar prompt.

## License

MIT
