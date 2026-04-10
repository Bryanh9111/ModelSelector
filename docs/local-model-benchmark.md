# Local Model Benchmark Report

Date: 2026-04-10
Hardware: Apple Silicon (local Ollama)
Benchmark script: `tests/local-model-bench.py`

## Models Tested

| Model | Size | Quantization |
|-------|------|-------------|
| gemma4:31b | 18.5GB | Q4_K_M |
| qwen3.5:35b | 22.2GB | default |
| qwen3.5:35b-nothink | 22.2GB | default |

## Test Dimensions

1. **Code Generation** - Python LIS algorithm with type hints
2. **Bug Finding** - 3 bugs across merge_sorted, binary_search, flatten
3. **Logical Reasoning** - Wolf/goat/cabbage river crossing
4. **Chinese Understanding** - React RSC vs Client Components (200 chars)
5. **JSON Structured Output** - Commit message analysis as valid JSON
6. **Code Refactoring** - ES5 JavaScript to ES2024+

## Speed Results (tok/s)

| Test | gemma4:31b | qwen3.5:35b | qwen3.5:35b-nothink |
|------|-----------|-------------|---------------------|
| Code Gen | 10.9 | 30.4 | 30.1 |
| Bug Find | 10.6 | 30.4 | 30.3 |
| Reasoning | 10.8 | 30.1 | 29.9 |
| Chinese | 11.3 | 29.9 | 30.0 |
| JSON | 11.4 | 30.5 | 30.5 |
| Refactor | 11.1 | 30.2 | 29.9 |

qwen3.5 is **2.7x faster** than gemma4 in raw token generation.

## Quality Results

| Test | gemma4:31b | qwen3.5:35b | qwen3.5:35b-nothink |
|------|-----------|-------------|---------------------|
| Code Gen | 9/10 (O(nlogn) bisect) | EMPTY | EMPTY |
| Bug Find | 9/10 (3/3 + fixes) | 9/10 (3/3 + examples) | 8/10 (3/3 concise) |
| Reasoning | 8/10 (correct 7 steps) | 9/10 (+ state tracking) | 8/10 (+ explanations) |
| Chinese | 9/10 (precise, in budget) | EMPTY | EMPTY |
| JSON | 8/10 (valid) | 8/10 (valid) | 8/10 (valid) |
| Refactor | 9/10 (toSorted, destructuring) | EMPTY | EMPTY |

## Critical Finding: qwen3.5 Thinking Token Black Hole

qwen3.5 models (including the "nothink" variant) consume thinking tokens from the `num_predict` budget via Ollama's generate API. With `num_predict: 4096`:

- **Tasks producing output**: bug finding (~1200 tokens), JSON (~1300 tokens), reasoning (~2500 tokens)
- **Tasks returning EMPTY**: code generation, refactoring, Chinese text (all hit 4096 ceiling with zero visible response)

The "nothink" variant does NOT actually disable thinking at the API level. It still generates thinking tokens internally; they are simply stripped from the response field. The token budget is consumed regardless.

Evidence: A simple "What is 2+2?" query consumed 237 tokens (thinking model) and 256 tokens (nothink model) to produce a one-word answer.

### Potential Fixes (Not Yet Validated)

1. Use Ollama chat API (`/api/chat`) with explicit `/no_think` system prompt
2. Set `num_predict: 16384+` to give thinking sufficient headroom
3. Use `raw` mode with custom template that suppresses `<think>` blocks

## T0 Routing Recommendation

Given these results, the ModelSelector T0 routing should use gemma4:31b as the default. Task-type-aware sub-routing within T0 is possible but adds complexity:

| Task Type | Recommended Model | Rationale |
|-----------|------------------|-----------|
| Code generation | gemma4:31b | qwen3.5 returns empty |
| Code refactoring | gemma4:31b | qwen3.5 returns empty |
| Chinese text | gemma4:31b | qwen3.5 returns empty |
| Bug finding / code review | qwen3.5:35b-nothink | 3x faster, equal quality |
| Reasoning / analysis | qwen3.5:35b | Deep thinking advantage |
| JSON / structured output | qwen3.5:35b-nothink | Fast + accurate |
| Default / unknown | gemma4:31b | Never returns empty |

## Reproduction

```bash
# Run full benchmark
python3 tests/local-model-bench.py

# Results saved to tests/bench-results/
```
