# ModelSelector: Claude Code Intelligent Model Router

> Design Spec v1.0 | 2026-04-10
> Validated via 2 rounds of multi-model debate (Gemini 0.36, Codex gpt-5.4, Sonnet 4.6, Opus 4.6)

## Problem

Claude Max subscription quota burns too fast, especially during EST morning peak (2x usage window). Most tasks don't need Opus 4.6 1M context. Simple doc edits, memory updates, formatting, and explanations waste premium quota that should be reserved for architecture, planning, and complex debugging.

## Goal

A zero-LLM-token scoring system (shell hook) that classifies each user prompt and routes to the optimal model tier, balancing capability, tool access, privacy, and quota pressure.

## Model Tiers

| Tier | Model | Config | Cost | Capability |
|------|-------|--------|------|------------|
| T0 | Ollama gemma4:31b | Q4_K_M, local | $0, no quota | Low |
| T1 | Codex gpt-5.4 | reasoning_effort=high, ChatGPT OAuth | $0 marginal (Plus sub) | High (comparable to Sonnet/Opus for reasoning) |
| T2 | Claude Haiku 4.5 | latest | Claude Max quota (low) | Low-Mid |
| T3 | Claude Sonnet 4.6 | latest | Claude Max quota (mid) | Mid-High |
| T4 | Claude Opus 4.6 | 1M context | Claude Max quota (high) | Highest |

### Key Economic Insight

T1 (GPT-5.4 high) is stronger than T2 (Haiku) and comparable to T3 (Sonnet) in raw capability. However, T2/T3/T4 have native Claude Code integration (Edit/Read/Agent tools, context continuity, permission model). This creates two independent axes: capability and tool access.

## Architecture: Gated Decision Tree with Static Routing Table

Linear scoring (T0 < T1 < T2 < T3 < T4) is structurally wrong because it conflates capability with tool affordance. Instead, use a two-axis gated router.

### Decision Flow

```
User Prompt
    |
    v
[P0] Privacy Override -----> match? ----> T0 (data never leaves machine)
    |
    v
[P1] Manual Override ------> match? ----> route to specified model
    |
    v
[P2] Preprocessing --------> lowercase, strip code fences/quotes,
    |                         negation proximity check
    v
[P3] Tool Dependency Gate --> TOOLS_NONE / TOOLS_REQUIRED
    |                    |
    v                    v
 Non-Claude          Claude-Native
 Branch              Branch
    |                    |
    v                    v
[P4] Capability       [P4] Capability
 Scoring               Scoring
    |                    |
    v                    v
 Lookup Table         Lookup Table
    |                    |
    v                    v
[P5] Modifiers --------> peak hour, correction signal, context size
    |
    v
 Final Tier
```

### Static Routing Table

| Capability | TOOLS_NONE | TOOLS_REQUIRED |
|------------|------------|----------------|
| LOW | T0 (Ollama gemma4:31b) | T2 (Claude Haiku 4.5) |
| MID | T1 (Codex gpt-5.4) | T3 (Claude Sonnet 4.6) |
| HIGH | T3 (Claude Sonnet 4.6) | T4 (Claude Opus 4.6 1M) |

**Why HIGH+NONE = T3 not T1:** HIGH tasks are deeply coupled to project context. Claude's skill/hook ecosystem, session continuity, and tool chain provide structural advantages even when tools aren't explicitly needed in the first prompt turn. T1 (codex exec) is stateless and context-isolated.

**Why T2 exists:** It is the low-cost entry point for Claude's native tool chain. Without T2, all tool-requiring tasks must use Sonnet or Opus, which burns quota 3-5x faster. T2 handles mechanical edits, simple file reads, and low-risk agentic chores.

## Detailed Gate Specifications

### P0: Privacy Override (Highest Priority)

If the prompt contains sensitive data, force local execution. Data never leaves the machine.

**Note:** P0 runs BEFORE preprocessing (P2), so it operates on raw `$PROMPT` with `grep -i` for case-insensitivity.

```bash
PRIVACY_PATTERN='(password|passwd|api[_-]?key|secret[_-]?key|private[_-]?key|bearer |token *= *|ssn|credit[_-]?card)'

if echo "$PROMPT" | grep -qiE "$PRIVACY_PATTERN"; then
    echo "T0"
    exit 0
fi
```

**Edge case:** Variable names like `api_key_validator` in code discussion may false-trigger at P0 since code-fence stripping hasn't run yet. Acceptable trade-off: privacy false-positive (route to T0) is safe; privacy false-negative (leak secrets) is not.

### P1: Manual Override

User explicitly requests a model. Respect unless it conflicts with privacy floor.

```bash
MODEL_OVERRIDE_PATTERN='\b(use|switch to|route to|prefer)\s+(opus|sonnet|haiku|codex|gpt|ollama|local|gemma)\b'

if echo "$prompt_lower" | grep -qiE "$MODEL_OVERRIDE_PATTERN"; then
    # extract target and map to tier
fi
```

### P2: Preprocessing (Zero-Token NLP)

Before scoring, sanitize the prompt to prevent false triggers from quoted code, stack traces, and code comments.

```bash
# Strip code fences and their contents
clean_prompt=$(echo "$PROMPT" | sed '/^```/,/^```/d')

# Strip inline code
clean_prompt=$(echo "$clean_prompt" | sed 's/`[^`]*`//g')

# Lowercase for matching
prompt_lower=$(echo "$clean_prompt" | tr '[:upper:]' '[:lower:]')

# Negation proximity: suppress trigger words near negation
# "don't refactor" should NOT score as "refactor"
# Note: BSD sed (macOS) does not support \b. Use space/start-of-line anchors instead.
prompt_lower=$(echo "$prompt_lower" | sed -E "s/(^| )(don.t|do not|no|not|avoid|without|skip) [a-z]+//g")
```

### P3: Tool Dependency Gate

Three-class detection with environment fallback for ambiguous cases.

```bash
# Strong TOOLS_REQUIRED signals
TOOL_YES='\b(edit|fix|refactor|rewrite|implement|create|delete|rename|update|modify|patch|write to|add to)\b'
TOOL_YES_FILE='(\.ts|\.js|\.py|\.rs|\.go|\.tsx|\.jsx|\.json|\.yaml|\.md|\.css|\.html|src/|lib/|app/|pages/|components/)'
TOOL_YES_CMD='\b(run test|grep|find file|read file|check lint|execute|build|deploy|commit|branch|PR)\b'

# Strong TOOLS_NONE signals
TOOL_NO='\b(explain|what is|how does|why|difference between|pros and cons|translate|summarize|brainstorm|in general|theoretically|write a plan|propose)\b'

classify_tools() {
    local p="$1"

    # Explicit no-tool signals win
    if echo "$p" | grep -qiE "$TOOL_NO" && ! echo "$p" | grep -qiE "$TOOL_YES"; then
        echo "NONE"
        return
    fi

    # Explicit tool signals
    if echo "$p" | grep -qiE "$TOOL_YES|$TOOL_YES_FILE|$TOOL_YES_CMD"; then
        echo "REQUIRED"
        return
    fi

    # Ambiguous: use environment
    # If inside a git repo, assume tools needed (99% of Claude Code usage in repos is code-related)
    if git rev-parse --git-dir >/dev/null 2>&1; then
        echo "REQUIRED"
    else
        echo "NONE"
    fi
}
```

### P4: Capability Scoring

Weighted keyword scoring across 4 dimensions, total = 100.

#### D1: Cognitive Complexity (weight: 35)

```bash
# HIGH signals (+8 each, cap 35)
HIGH_COMPLEXITY='\b(architect|system design|refactor.*across|migrat|optimize.*algorithm|debug.*race|implement.*from scratch|trade[_-]?off|reverse engineer|redesign)\b'

# MULTI-STEP signals (+5 each)
MULTI_STEP='\b(then|after that|followed by|step [0-9]|first.*then.*finally|pipeline|orchestrat|end[_-]to[_-]end|full[_-]stack)\b'

# LOW signals (-5 each)
LOW_COMPLEXITY='\b(how to|syntax|boilerplate|comment|docstring|hello world|simple|basic|beginner|tutorial|rename|reformat)\b'
```

#### D2: Domain Expertise & Risk (weight: 30)

```bash
# EXPERT signals (+10 each, forces min_tier)
EXPERT_DOMAIN='\b(cryptograph|zero[_-]?knowledge|consensus|distributed transaction|memory safety|undefined behavior|compiler|JIT|SIMD|CUDA|formal verification|type theory)\b'

# RISK signals (+8 each)
HIGH_RISK='\b(auth|authorization|billing|payment|schema|migration|public api|breaking change|prod|production|security|vulnerability|exploit|xss|csrf|injection)\b'

# SYSTEMS signals (+5 each)
SYSTEMS='\b(syscall|mmap|socket|epoll|mutex|semaphore|atomic|cache coherenc|POSIX|pthread)\b'

# GENERIC signals (-5 each)
GENERIC='\b(CRUD|REST API|todo app|hello world|simple script|basic|beginner)\b'
```

#### D3: Scope & Volume (weight: 20)

```bash
# Prompt length as proxy
PROMPT_LEN=${#PROMPT}
if (( PROMPT_LEN > 4000 )); then SCOPE_SCORE=20
elif (( PROMPT_LEN > 1500 )); then SCOPE_SCORE=10
elif (( PROMPT_LEN < 100 )); then SCOPE_SCORE=-5
fi

# Scope keywords (+5 each)
BROAD_SCOPE='\b(everywhere|across the project|all files|entire|global|multiple files|whole codebase|full implementation|comprehensive)\b'

# Narrow scope keywords (-5 each)
NARROW_SCOPE='\b(one[_-]?liner|quick fix|snippet|just the|brief|short|single file|this function)\b'
```

#### D4: Intent Modifiers (weight: 15)

```bash
# Educational dampener: reduce total score by 20%
EDUCATIONAL='\b(explain|teach|what is|for learning|toy example|walk me through|help me understand)\b'

# Deterministic transform dampener: reduce by 20%
TRANSFORM='\b(convert|translate|transpile|reformat|rename|replace.*with|extract|summarize)\b'

# Urgency down: reduce by 15%
URGENCY_DOWN='\b(quick|fast|brief|draft|placeholder|stub|skeleton|boilerplate|scaffold|good enough)\b'

# Urgency up: increase by 15%
URGENCY_UP='\b(production[_-]?ready|enterprise|robust|thorough|careful|critical|mission[_-]?critical)\b'

# Note: CORRECTION is handled exclusively in P5 (post-routing tier escalation),
# NOT here in D4 pre-routing scoring. This prevents double-counting.
# See P5 Modifiers section for the CORRECTION pattern and logic.
```

#### Capability Classification

**Hit cap mechanics:** Each dimension has a maximum contribution (D1: 35, D2: 30, D3: 20, D4: 15). Within a dimension, each unique regex pattern match adds its points, but the dimension total is capped. For example, a prompt matching 5 D1 patterns at +8 each = 40, capped to 35. Duplicate keyword hits within a single pattern do not add points (e.g., "auth auth auth" counts as one D2 hit).

```bash
classify_capability() {
    local score=0
    # Accumulate scores from D1-D4, cap each dimension independently

    # Apply dampeners
    if echo "$prompt_lower" | grep -qiE "$EDUCATIONAL"; then
        score=$(( score * 80 / 100 ))
    fi
    if echo "$prompt_lower" | grep -qiE "$TRANSFORM"; then
        score=$(( score * 80 / 100 ))
    fi

    # Classify
    if (( score >= 55 )); then echo "HIGH"
    elif (( score >= 25 )); then echo "MID"
    else echo "LOW"
    fi
}
```

### P5: Modifiers (Post-Routing Adjustments)

Applied after the routing table lookup. These can shift the tier up or down by one level.

```bash
# Peak hour: EST 9am-1pm = aggressive downshift
HOUR=$(TZ=America/New_York date +%H)
IS_PEAK=false
if (( HOUR >= 9 && HOUR <= 12 )); then
    IS_PEAK=true
fi

# Apply modifiers
apply_modifiers() {
    local tier=$1

    # Hard floor: expert domain forces min T3
    if echo "$prompt_lower" | grep -qiE "$EXPERT_DOMAIN"; then
        (( tier < 3 )) && tier=3
    fi

    # Hard floor: security + production co-occurrence forces T4
    if echo "$prompt_lower" | grep -qiE '\b(security|vulnerab)' && \
       echo "$prompt_lower" | grep -qiE '\b(prod|production|deploy)\b'; then
        tier=4
    fi

    # Hard floor: long input forces min T2 (T0 context window too small)
    if (( PROMPT_LEN > 6000 )) && (( tier < 2 )); then
        tier=2
    fi

    # Correction signal: escalate one tier
    if echo "$prompt_lower" | grep -qiE "$CORRECTION"; then
        (( tier < 4 )) && tier=$(( tier + 1 ))
    fi

    # Peak hour: downshift one tier, but NEVER below any hard floor
    if $IS_PEAK && (( tier > 0 )); then
        local min_floor=0
        # Preserve ALL hard floors (must mirror every hard floor set above)
        echo "$prompt_lower" | grep -qiE "$EXPERT_DOMAIN" && min_floor=3
        (( PROMPT_LEN > 6000 )) && (( min_floor < 2 )) && min_floor=2
        # Security+production hard floor: MUST be preserved during peak
        if echo "$prompt_lower" | grep -qiE '(security|vulnerab)' && \
           echo "$prompt_lower" | grep -qiE '(prod|production|deploy)'; then
            min_floor=4
        fi

        local new_tier=$(( tier - 1 ))
        (( new_tier < min_floor )) && new_tier=$min_floor
        tier=$new_tier
    fi

    echo $tier
}
```

## Output Format

The hook outputs a structured recommendation that Claude Code's context can act on.

```bash
# Example output injected into conversation context:
echo "━━━ ModelSelector ━━━"
echo ""
echo "  Task: ${capability} complexity, tools ${tools_needed}"
echo "  Route: T${tier} (${MODEL_NAME})"
if $IS_PEAK; then
    echo "  Peak: EST morning peak active (downshifted)"
fi
echo ""
echo "  Recommendation: ${ACTION_GUIDANCE}"
```

### Action Guidance by Tier

| Tier | Action | Mechanism |
|------|--------|-----------|
| T0 | Dispatch to Ollama via curl | Hook calls `curl localhost:11434/api/generate` and injects response |
| T1 | Dispatch to Codex | Hook runs `codex exec --full-auto "..."` |
| T2 | Use Haiku sub-agent | Output tells Claude to `Agent(model: "haiku", ...)` |
| T3 | Use Sonnet sub-agent | Output tells Claude to `Agent(model: "sonnet", ...)` |
| T4 | Stay in current Opus session | Output confirms Opus is appropriate |

## Implementation Plan

### Phase 1: Shell Hook (MVP)
- `~/.claude/hooks/model-selector.sh` - the scoring engine
- Regex-only, zero LLM tokens
- Outputs recommendation into conversation context
- Integrates with existing `skill-router.sh` (runs before or after)

### Phase 2: T0/T1 Auto-Dispatch
- T0: Hook directly calls Ollama API and injects response (bypasses Claude entirely)
- T1: Hook runs `codex exec` for non-tool tasks
- **Open design question:** `UserPromptSubmit` hooks inject stdout as `additionalContext` - they do not suppress Claude's response. True bypass (Claude never processes the prompt) may require `PreToolUse` exit-code-2 blocking or a different hook event. This mechanism needs further investigation before Phase 2 implementation.

### Phase 3: Feedback Loop
- Track routing decisions and outcomes
- Log to `~/.claude-model-selector/routing-log.jsonl`
- Weekly retro: which routing decisions were wrong? Tune thresholds.

### Phase 4: Claude Code Skill
- Package as a proper Claude Code skill (`/model-select`)
- Allow manual override (`/model-select opus`)
- Dashboard: quota usage by tier, savings estimate

## File Structure

```
ModelSelector/
  docs/
    superpowers/specs/
      2026-04-10-model-selector-design.md  (this file)
  src/
    model-selector.sh        # main hook script
    lib/
      preprocess.sh           # P2: code-fence stripping, negation handling
      privacy.sh              # P0: privacy override
      tools-gate.sh           # P3: tool dependency classification
      capability.sh           # P4: capability scoring
      modifiers.sh            # P5: peak hour, correction, hard floors
      router.sh               # routing table lookup
      dispatch.sh             # T0/T1 auto-dispatch logic
    config/
      thresholds.json         # tunable scoring thresholds
      models.json             # model configs (endpoints, auth)
  tests/
    test-router.sh            # unit tests for routing decisions
    fixtures/                 # sample prompts with expected tiers
  CLAUDE.md                   # project instructions
  README.md                   # documentation
```

## Design Decisions Log

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Routing topology | Gated decision tree | Linear scoring, 2D weighted matrix | Shell-friendly, avoids conflating capability with tool access |
| Tool detection fallback | IS_REPO environment check | Always assume tools needed, Always assume no tools | 99% of Claude Code repo usage is code-related |
| T1 ceiling | MID (HIGH goes to T3) | HIGH (all non-tool to T1) | Claude ecosystem advantages for complex tasks outweigh T1 capability parity |
| T2 retention | Keep as narrow specialist | Remove entirely | Without T2, all tool tasks burn Sonnet/Opus quota |
| Peak hour handling | Downshift 1 tier, respect floors | Aggressive downshift, No time-based routing | Balances quota savings with task quality |
| Privacy handling | Hard override to T0 | Soft suggestion | Security is non-negotiable |
| Scoring method | Regex keyword matching | LLM-based classification | Zero token overhead is a hard requirement |

## Validation Source

This design was validated through structured multi-model debate:

- **Round 1 (Scoring Dimensions):** Gemini proposed 5 dimensions, Sonnet proposed 7, Codex proposed 17 + dampeners. Synthesized to 6 dimensions + dampeners.
- **Round 2 (Dual-Axis Architecture):** All three models agreed linear routing is wrong. Codex proposed gated tree, Gemini proposed 2D matrix, Sonnet proposed static routing table with environment fallback. Final: gated tree + static table (combines simplicity with correctness).
- **Key unique contributions:** Gemini (correction signal, meta-query override), Codex (dampeners, quote stripping, T1 economics), Sonnet (privacy axis, IS_REPO fallback, T1 ceiling = MID, "cost axis is unnecessary with flat fee").
