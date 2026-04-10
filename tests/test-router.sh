#!/usr/bin/env bash
# ModelSelector Test Suite
# Tests the scoring engine against known prompt -> tier mappings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="${SCRIPT_DIR}/../src/model-selector.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0
total=0

assert_tier() {
    local expected="$1"
    local prompt="$2"
    local description="${3:-}"
    total=$(( total + 1 ))

    actual=$(echo "$prompt" | "$SELECTOR" 2>/dev/null)

    if [[ "$actual" == "$expected" ]]; then
        passed=$(( passed + 1 ))
        echo -e "  ${GREEN}PASS${NC} [$expected] $description"
    else
        failed=$(( failed + 1 ))
        echo -e "  ${RED}FAIL${NC} [$expected != $actual] $description"
        if [[ -n "${VERBOSE:-}" ]]; then
            echo "$prompt" | "$SELECTOR" --verbose 2>/dev/null | sed 's/^/    /'
        fi
    fi
}

echo "━━━ ModelSelector Test Suite ━━━"
echo ""

# ============================================================
echo "P0: Privacy Override"
# ============================================================
assert_tier "T0" "my password is hunter2 please check it" "password in prompt"
assert_tier "T0" "here's the api_key=sk-abc123 for the service" "api_key in prompt"
assert_tier "T0" "the bearer token for auth" "bearer token"

# ============================================================
echo ""
echo "P1: Manual Override"
# ============================================================
assert_tier "T4" "use opus to design this system" "explicit opus request"
assert_tier "T3" "switch to sonnet for this" "explicit sonnet request"
assert_tier "T0" "use ollama for this simple task" "explicit ollama request"
assert_tier "T1" "route to codex please" "explicit codex request"

# ============================================================
echo ""
echo "T0: Trivial / Local (LOW + TOOLS_NONE)"
# ============================================================
assert_tier "T0" "what is a for loop" "basic question"
assert_tier "T0" "explain how to install node" "tutorial question"
assert_tier "T0" "how to use Python" "simple how-to"

# ============================================================
echo ""
echo "T1: Codex / GPT-5.4 (MID + TOOLS_NONE)"
# ============================================================
assert_tier "T1" "explain the difference between TCP and UDP protocols, their use cases, reliability guarantees, and when to prefer one over the other in production systems" "mid-complexity explanation"
assert_tier "T1" "what are the pros and cons of microservices versus monolith architecture for a startup with a small team and growing user base" "comparison question"
assert_tier "T1" "summarize how React server components work in Next.js, including the boundary between server and client components, data fetching patterns, streaming responses, and the overall rendering strategy" "summarize request"

# ============================================================
echo ""
echo "T2: Haiku (LOW + TOOLS_REQUIRED)"
# ============================================================
assert_tier "T2" "rename the variable foo to bar in utils.ts" "simple rename"
assert_tier "T2" "add a comment to this function in src/main.py" "add comment"
assert_tier "T2" "fix the typo in README.md" "fix typo"

# ============================================================
echo ""
echo "T3: Sonnet (MID + TOOLS_REQUIRED or HIGH + TOOLS_NONE)"
# ============================================================
assert_tier "T3" "refactor the auth module to use JWT tokens and update all the related tests" "mid refactor with tools"
assert_tier "T3" "implement a rate limiter for the API endpoint in src/api.ts with sliding window algorithm" "implement feature"
assert_tier "T3" "debug why the integration tests are failing in the payment module and fix the root cause" "debug with tools"

# ============================================================
echo ""
echo "T4: Opus (HIGH + TOOLS_REQUIRED)"
# ============================================================
assert_tier "T4" "architect a new microservices system for our e-commerce platform with authentication, payment processing, and inventory management. Design the API contracts, implement the service mesh, and refactor the existing monolith across multiple files" "complex architecture"
assert_tier "T4" "refactor the entire authentication system across all modules to implement zero-knowledge proofs with formal verification of the cryptographic protocol" "expert domain + tools"

# ============================================================
echo ""
echo "Hard Floors"
# ============================================================
assert_tier "T4" "check the security vulnerability in our production deploy pipeline" "security+production -> T4"

# ============================================================
echo ""
echo "Dampeners"
# ============================================================
assert_tier "T0" "explain what is a mutex" "educational dampener"
assert_tier "T1" "translate this Python function to Go, including all the type annotations, error handling patterns, and idiomatic conventions that are standard in production Go codebases" "transform dampener"

# ============================================================
echo ""
echo "Correction Signal"
# ============================================================
assert_tier "T3" "that didn't work, the rename in utils.ts still has errors" "correction escalates T2->T3"

# ============================================================
echo ""
echo "━━━ Results ━━━"
echo -e "  Total:  $total"
echo -e "  ${GREEN}Passed: $passed${NC}"
if (( failed > 0 )); then
    echo -e "  ${RED}Failed: $failed${NC}"
    echo ""
    echo "Run with VERBOSE=1 to see scoring details for failures:"
    echo "  VERBOSE=1 bash tests/test-router.sh"
    exit 1
else
    echo -e "  ${GREEN}All tests passed!${NC}"
fi
