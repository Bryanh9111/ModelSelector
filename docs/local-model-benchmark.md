# Local Model Benchmark Report

Date: 2026-04-10
Hardware: Apple Silicon M4 Pro 48GB (local Ollama)
Benchmark script: `tests/local-model-bench.py`

## Models Tested

### Round 1 (3 models)

| Model | Size | Type |
|-------|------|------|
| gemma4:31b | 18.5GB | dense |
| qwen3.5:35b | 22.2GB | MoE (35B/3B active) |
| qwen3.5:35b-nothink | 22.2GB | MoE (35B/3B active) |

### Round 2 (added 2 models)

| Model | Size | Type | Result |
|-------|------|------|--------|
| qwen3:32b | ~19GB | dense + thinking | **Removed** - thinking token timeout |
| deepseek-r1:32b | ~19GB | dense + thinking | **Removed** - thinking token timeout |

## Test Dimensions

1. **Code Generation** - Python LIS algorithm with type hints
2. **Bug Finding** - 3 bugs across merge_sorted, binary_search, flatten
3. **Logical Reasoning** - Wolf/goat/cabbage river crossing
4. **Chinese Understanding** - React RSC vs Client Components (200 chars)
5. **JSON Structured Output** - Commit message analysis as valid JSON
6. **Code Refactoring** - ES5 JavaScript to ES2024+

## Speed Results (tok/s)

| Test | gemma4:31b | qwen3:32b | deepseek-r1:32b | qwen3.5:35b | qwen3.5:35b-nothink |
|------|-----------|-----------|-----------------|-------------|---------------------|
| Code Gen | 11.1 | TIMEOUT | TIMEOUT | 29.9 (empty) | 29.9 (empty) |
| Bug Find | 11.2 | 11.7 | TIMEOUT | 30.5 | 30.2 |
| Reasoning | 11.1 | TIMEOUT | TIMEOUT | 30.1 (empty) | 30.2 |
| Chinese | 11.4 | 11.9 | 12.2 | 30.0 (empty) | 30.1 (empty) |
| JSON | 11.6 | 11.9 | 12.3 | 30.2 | 30.3 |
| Refactor | 11.3 | 11.7 | 12.2 | 30.0 (empty) | 30.0 (empty) |

## Quality Results

| Test | gemma4:31b | qwen3:32b | deepseek-r1:32b | qwen3.5:35b | qwen3.5-nt |
|------|-----------|-----------|-----------------|-------------|------------|
| Code Gen | **9**/10 | TIMEOUT | TIMEOUT | EMPTY | EMPTY |
| Bug Find | **9**/10 | **9**/10 | TIMEOUT | **9**/10 | 8/10 |
| Reasoning | **8**/10 | TIMEOUT | TIMEOUT | 9/10 | 8/10 |
| Chinese | **9**/10 | 8/10 | 7/10 | EMPTY | EMPTY |
| JSON | **8**/10 | 8/10 | 6/10 (markdown wrapped) | 8/10 | 8/10 |
| Refactor | **9**/10 | 7/10 (`.compare()` bug) | 8/10 | EMPTY | EMPTY |

## Reliability (completion rate)

```
gemma4:31b          ████████████ 6/6 (100%)
qwen3.5:35b-nothink ██████       3/6 (50%)
qwen3:32b           ██████       3/6 (50%)
qwen3.5:35b         ██████       3/6 (50%)
deepseek-r1:32b     ████         2/6 (33%)
```

## Critical Finding: Thinking Token Black Hole

All thinking models (qwen3, qwen3.5, deepseek-r1) consume thinking tokens from the `num_predict` budget via Ollama's generate API. With `num_predict: 4096` and a 180s timeout:

- **qwen3:32b**: 3/6 timeouts (codegen, reasoning timed out at 180s)
- **deepseek-r1:32b**: 4/6 timeouts (worst reliability of all models)
- **qwen3.5:35b**: 3/6 empty responses (thinking consumed all tokens)
- **qwen3.5:35b-nothink**: 3/6 empty (nothink does NOT actually disable thinking)

Evidence: A simple "What is 2+2?" query consumed 237 tokens (qwen3.5 thinking) and 256 tokens (qwen3.5 nothink) to produce a one-word answer.

### Additional Issues Found in Round 2

- **qwen3:32b** produced incorrect JavaScript (`a.name.compare()` instead of `localeCompare()`)
- **deepseek-r1:32b** wrapped JSON in markdown code fences despite explicit "no markdown" instruction
- Both dense thinking models (~12 tok/s) were no faster than gemma4 (~11 tok/s) for actual output

### Potential Fixes (Not Yet Validated)

1. Use Ollama chat API (`/api/chat`) with explicit `/no_think` system prompt
2. Set `num_predict: 16384+` to give thinking sufficient headroom
3. Use `raw` mode with custom template that suppresses `<think>` blocks

## Decision: T0 = gemma4:31b

gemma4:31b is the only model with 100% completion rate across all test dimensions. It is the correct and validated T0 default for ModelSelector.

qwen3:32b and deepseek-r1:32b have been removed from local Ollama (`ollama rm`). qwen3.5:35b and qwen3.5:35b-nothink are retained as potential secondary models for short-output tasks (bug review, JSON) where their 3x speed advantage matters.

## Reproduction

```bash
# Run full benchmark
python3 tests/local-model-bench.py

# Results saved to tests/bench-results/
```
