#!/usr/bin/env bash
# End-to-end test for --dir flag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_LOOP="$SCRIPT_DIR/../agent-loop.sh"

pass=0
fail=0

assert_ok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        ((pass++)) || true
    else
        echo "  FAIL: $desc"
        ((fail++)) || true
    fi
}

assert_fail() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        ((pass++)) || true
    else
        echo "  FAIL: $desc (expected failure)"
        ((fail++)) || true
    fi
}

assert_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -qF -- "$pattern"; then
        echo "  PASS: $desc"
        ((pass++)) || true
    else
        echo "  FAIL: $desc (pattern '$pattern' not found)"
        ((fail++)) || true
    fi
}

echo "=== --dir flag tests ==="

# Test 1: --help shows --dir
output=$("$AGENT_LOOP" --help 2>&1)
assert_contains "--help includes --dir" "$output" "--dir"

# Test 2: --dir with nonexistent path fails
assert_fail "--dir /nonexistent fails" "$AGENT_LOOP" --dir /nonexistent --dry-run "$SCRIPT_DIR/minimal-tasks.md"

# Test 3: --dir with valid path + dry-run works
output=$("$AGENT_LOOP" --dir /tmp --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
assert_contains "dry-run with --dir shows target" "$output" "target:"
assert_contains "dry-run with --dir shows /tmp" "$output" "/tmp"

# Test 4: without --dir, no target line shown
output=$("$AGENT_LOOP" --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
if echo "$output" | grep -q "target:"; then
    echo "  FAIL: no --dir should not show target line"
    ((fail++)) || true
else
    echo "  PASS: no --dir omits target line"
    ((pass++)) || true
fi

# Test 5: --dir + --status works on target dir
output=$("$AGENT_LOOP" --dir /tmp --status 2>&1)
assert_contains "--dir + --status checks target" "$output" "No active run found"

# Test 6: --dir + --reset works on target dir
mkdir -p /tmp/.agent-loop
echo '{}' > /tmp/.agent-loop/state.json
output=$("$AGENT_LOOP" --dir /tmp --reset 2>&1)
assert_contains "--dir + --reset clears target state" "$output" "State cleared"
if [[ ! -d /tmp/.agent-loop ]]; then
    echo "  PASS: --reset removed /tmp/.agent-loop"
    ((pass++)) || true
else
    echo "  FAIL: --reset did not remove /tmp/.agent-loop"
    ((fail++)) || true
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
