# ModelSelector

Intelligent model routing for AI coding assistants. Scores your prompt locally (zero LLM tokens, pure regex), picks the optimal model tier, and dispatches to the right provider automatically.

**Provider-agnostic.** Works with Claude, Codex, Amp, Gemini, OpenAI API, Ollama, or any combination.

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

Simple tasks never touch expensive models. Complex tasks get the firepower they need.

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
1. Symlink the scoring engine and hook to `~/.claude/hooks/` (if Claude is available)
2. Register the hook in Claude Code settings (if applicable)
3. Add the `ms` alias to your shell
4. Generate a provider config at `~/.config/model-selector/providers.sh`

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

| Your RAM | Recommended Model | Size |
|----------|------------------|------|
| 8GB | gemma3:4b | ~2.5GB |
| 16GB | gemma3:12b | ~7GB |
| 32GB | gemma4:31b (Q4) | ~18.5GB |
| 48GB+ | gemma4:31b | ~18.5GB |

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

Supports English and Chinese prompts.

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
# Run test suite (25 cases)
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
  install.sh                     # Installer
  config/
    providers.sh                 # Default provider config
    examples/
      claude-full.sh             # Full Claude setup
      no-claude.sh               # Codex + Amp + Ollama
      ollama-only.sh             # Free tier only
      openai-gemini.sh           # OpenAI API + Gemini
  src/
    model-selector.sh            # Scoring engine (450+ lines, pure regex)
    hook-model-selector.sh       # Claude Code hook (Layer 2)
  tests/
    test-router.sh               # Test suite (25 cases)
    local-model-bench.py         # Local model benchmark
  docs/
    local-model-benchmark.md     # Benchmark report
    superpowers/specs/            # Design spec
```

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

**Q: What about the Anthropic Advisor Tool?**
The Advisor Tool (beta, April 2026) lets Sonnet consult Opus on hard decisions. When Claude Code CLI supports `--advisor`, ModelSelector's T3/T4 tiers can merge. We're tracking this for a future update.

## License

MIT
