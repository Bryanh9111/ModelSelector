#!/usr/bin/env python3
"""Local Model Benchmark - Compare Ollama models across 6 dimensions."""

import json, time, os, sys, urllib.request, urllib.error, textwrap

OLLAMA_URL = "http://localhost:11434/api/generate"
MODELS = ["gemma4:31b", "qwen3:32b", "deepseek-r1:32b", "qwen3.5:35b", "qwen3.5:35b-nothink"]
RESULTS_DIR = os.path.join(os.path.dirname(__file__), "bench-results")
os.makedirs(RESULTS_DIR, exist_ok=True)

TESTS = {
    "1_codegen": "Write a Python function that takes a list of integers and returns the longest increasing subsequence. Include type hints. Only output the function, no explanation.",

    "2_bugfind": textwrap.dedent("""\
        Find all bugs in this code and explain each one briefly:

        ```python
        def merge_sorted(a, b):
            result = []
            i = j = 0
            while i < len(a) and j < len(b):
                if a[i] <= b[j]:
                    result.append(a[i])
                    i += 1
                else:
                    result.append(b[j])
                    j += 1
            return result

        def binary_search(arr, target):
            low, high = 0, len(arr)
            while low < high:
                mid = (low + high) / 2
                if arr[mid] == target:
                    return mid
                elif arr[mid] < target:
                    low = mid + 1
                else:
                    high = mid
            return -1

        def flatten(nested):
            for item in nested:
                if isinstance(item, list):
                    flatten(item)
                else:
                    yield item
        ```"""),

    "3_reasoning": "A farmer has a wolf, a goat, and a cabbage. He needs to cross a river with a boat that can only carry him and one item. If left alone: wolf eats goat, goat eats cabbage. What is the minimum number of crossings? List each crossing step.",

    "4_chinese": "用中文解释 React Server Components 和 Client Components 的区别，包括：1) 各自的渲染位置 2) 什么时候用哪个 3) 给一个实际的代码组织建议。控制在200字以内。",

    "5_json": 'Analyze this git commit message and output ONLY valid JSON (no markdown, no explanation):\n{"quality": 1-10, "issues": ["list of issues"], "improved": "better commit message"}\n\nCommit message: "fixed stuff and updated things"',

    "6_refactor": textwrap.dedent("""\
        Refactor this JavaScript to modern ES2024+ style. Output only the refactored code:

        ```javascript
        var users = [];
        for (var i = 0; i < data.length; i++) {
            if (data[i].age >= 18) {
                var user = {};
                user.name = data[i].firstName + " " + data[i].lastName;
                user.email = data[i].email.toLowerCase();
                user.isActive = data[i].status === "active" ? true : false;
                users.push(user);
            }
        }
        var sorted = users.sort(function(a, b) {
            if (a.name < b.name) return -1;
            if (a.name > b.name) return 1;
            return 0;
        });
        console.log("Found " + sorted.length + " users");
        ```"""),
}


def run_prompt(model: str, test_name: str, prompt: str) -> dict:
    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": 4096, "temperature": 0.3},
    }).encode()

    start = time.time()
    try:
        req = urllib.request.Request(OLLAMA_URL, data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read())
        response = data.get("response", "[empty]")
        eval_count = data.get("eval_count", 0)
        eval_duration_ns = data.get("eval_duration", 0)
    except Exception as e:
        response = f"[ERROR: {e}]"
        eval_count = 0
        eval_duration_ns = 0

    elapsed = time.time() - start
    tps = eval_count / (eval_duration_ns / 1e9) if eval_duration_ns > 0 else 0

    # Save result
    safe_model = model.replace(":", "_").replace(".", "_")
    outfile = os.path.join(RESULTS_DIR, f"{test_name}__{safe_model}.txt")
    with open(outfile, "w") as f:
        f.write(f"=== {model} | {test_name} | {elapsed:.1f}s | {tps:.1f} tok/s ===\n\n")
        f.write(response)

    print(f"  \033[32m✓\033[0m {model:<25} {test_name:<14} {elapsed:>5.1f}s  {tps:>5.1f} tok/s")
    return {"model": model, "test": test_name, "time": elapsed, "tps": tps, "response": response}


def main():
    print("━━━ Local Model Benchmark ━━━")
    print(f"Models: {', '.join(MODELS)}")
    print(f"Tests:  {len(TESTS)}")
    print(f"Total:  {len(TESTS) * len(MODELS)} runs")
    print()

    all_results = []

    for test_name, prompt in TESTS.items():
        print(f"── {test_name} ──")
        for model in MODELS:
            result = run_prompt(model, test_name, prompt)
            all_results.append(result)
        print()

    # Summary table
    print("━━━ Speed Summary (tok/s) ━━━")
    print(f"{'Test':<14} {'gemma4:31b':>12} {'qwen3.5:35b':>14} {'qwen-nothink':>14}")
    print("─" * 56)
    for test_name in TESTS:
        row = [test_name]
        for model in MODELS:
            r = next(x for x in all_results if x["model"] == model and x["test"] == test_name)
            row.append(f"{r['tps']:.1f}")
        print(f"{row[0]:<14} {row[1]:>12} {row[2]:>14} {row[3]:>14}")

    print()
    print(f"Results saved to: {RESULTS_DIR}/")


if __name__ == "__main__":
    main()
