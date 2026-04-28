# ModelSelector Postmortem

**Status**: Archived 2026-04-28
**Lifetime**: 2026-04-10 (design) -> 2026-04-28 (decommission), 18 days
**Verdict**: Layer 2 + 3 (in-session auto-routing) increased token consumption rather than reducing it. Layer 1 (CLI wrapper) was functional but never used in practice.

## Hypothesis

Auto-classify each user prompt and dispatch trivial tasks to cheaper models (Ollama / Codex / Haiku / Sonnet), reserving Opus for genuinely complex work. Expected: 60-80% reduction in flagship-model usage.

Three layers:
- **Layer 1 (`ms` CLI)**: Explicit invocation. User types `ms "prompt"`, scoring engine picks tier, dispatches.
- **Layer 2 (`UserPromptSubmit` hook)**: In-session auto-routing. Hook scores each prompt and prints a recommendation.
- **Layer 3 (CLAUDE.md directive)**: Orchestrator (Opus) reads the hook output and dispatches a sub-agent at the recommended tier.

## What Actually Happened

### Failure Mode

For roughly 70% of user prompts (conversation, recall, follow-up questions, opinion-seeking, meta-discussion), the engine classified LOW/MID and forced sub-agent dispatch via `Agent(model: "sonnet", ...)`. Each dispatch incurred:

1. **Cold-start context packing** -- Sub-agents inherit no session memory. The orchestrator had to repack all relevant context into the sub-agent's prompt -- often 30-50k tokens for a 2-sentence reply.
2. **Result relay** -- Sub-agent output came back to the orchestrator, which then re-explained it to the user.
3. **Memory discontinuity** -- Multi-turn conversation broke when the sub-agent had no memory of prior turns; the orchestrator had to re-establish context every dispatch.

**Empirical cost ratio: 5-20x more tokens per turn vs. orchestrator answering directly.**

### Why More SKIP Patterns Wouldn't Have Saved It

The first instinct was to expand the SKIP whitelist (conversation/recall/dialogue patterns). But:
- A blacklist of "don't route this" always has holes -- new prompt shapes leak through
- The default direction was wrong: "route by default, skip on match" inverts the correct prior

The correct prior is: **default to orchestrator (cache-warm, free-ish), only route out when prompt is clearly an independent code task with sharp input/output boundaries**. Implementing this requires a positive-trigger whitelist (file paths, build/test commands, broad-scope keywords) instead of negative SKIP patterns. Effort cost: ~2 hours. Decision: not worth it given the alternatives below already work.

### Why Anthropic Prompt Cache + RTK Already Solved It

| Layer | Mechanism | Savings | Cost |
|-------|-----------|---------|------|
| **Anthropic prompt cache** | Cache-hit input pricing ~1/10 of fresh input | Repeated context across turns is essentially free | Automatic, zero config |
| **RTK (Rust Token Killer)** | Regex-based tool output rewriting | 60-93% on tool outputs | No information loss risk, ~1000x faster than LLM-based compression |

These capture the meaningful savings without ModelSelector's failure modes. There is no input-side gap left for a model-routing layer to fill.

### A Tempting Variant That Also Doesn't Work

> "Use local Gemma4 to preprocess context before sending to Claude/Codex/Gemini."

Three problems:
1. **Weaker judgment** -- Gemma4 31B deciding what a stronger model needs = guaranteed information loss
2. **Slower than the cloud** -- Local 30-50 tok/s means 100-200s to summarize 50k context vs 5-30s for Claude to consume it directly
3. **Cache miss** -- Anthropic cache-hit input is already $0.30/MTok. Saving 40k tokens at cache-hit pricing is $0.012/call, not worth the latency

The right partition is task-level (T0 handles a trivial task end-to-end), not pipeline-level (preprocess everything for a stronger model).

## Decommission Actions (2026-04-28)

- Removed `hook-model-selector.sh` from `~/.claude/settings.json` `UserPromptSubmit` array
- Deleted 3 symlinks in `~/.claude/hooks/` (hook + engine + rtk-stats bridge)
- Removed `ms` alias from `~/.zshrc`
- `install.sh` aborts unless `MS_FORCE_INSTALL=1` is set
- README + project CLAUDE.md updated with ARCHIVED notice
- Repository preserved as design study and warning

RTK PreToolUse hook (`rtk-rewrite.sh`) is independent and remains active.

## Lessons (for future model-routing experiments)

1. **Sub-agent dispatch is not free.** Cold-start context packing dominates total cost for short interactions. Only dispatch when the task is independent and the orchestrator gains nothing by handling it directly.
2. **The default matters more than the rules.** Black-list patches accumulate forever. Positive-trigger whitelists are more honest about what the system actually handles.
3. **Don't compete with prompt cache.** Provider cache layers do more than most people realize. Build on top, not around.
4. **Local LLM as context preprocessor is a trap.** Weaker model deciding for stronger model = information loss the stronger model would have used. Partition by task, not by pipeline stage.

## Surviving Components (Reference Only)

| Path | Status | Why kept |
|------|--------|----------|
| `src/model-selector.sh` | Inert | Reference for keyword-based prompt classification (D1-D4 scoring, dual-language EN+ZH patterns) |
| `tests/test-router.sh` | Passes | Engine logic is independently testable; useful if anyone re-uses scoring code |
| `docs/superpowers/specs/2026-04-10-model-selector-design.md` | Frozen | Original design spec |
| `docs/debates/2026-04-11-rtk-integration/debate.md` | Frozen | Multi-model debate record from design phase |
| `ms.sh` + `src/rtk-stats.sh` | Inert | Layer 1 still callable but not aliased; RTK bridge no longer triggered |
