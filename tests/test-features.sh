#!/usr/bin/env bash
# Tests for openclaw-inspired features
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

assert_not_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if ! echo "$output" | grep -qF -- "$pattern"; then
        echo "  PASS: $desc"
        ((pass++)) || true
    else
        echo "  FAIL: $desc (pattern '$pattern' should not be present)"
        ((fail++)) || true
    fi
}

# ============================================================
echo "=== Boot file tests ==="

# Setup temp dir for boot file tests
BOOT_DIR=$(mktemp -d)
trap 'rm -rf "$BOOT_DIR"' EXIT

# Test: boot.md in .agent-loop/ is detected in dry-run banner
mkdir -p "$BOOT_DIR/.agent-loop"
echo "This is a test project." > "$BOOT_DIR/.agent-loop/boot.md"
output=$("$AGENT_LOOP" --dir "$BOOT_DIR" --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
assert_contains "boot.md shown in banner" "$output" "boot:"

# Test: no boot file = no boot line in banner
NOBOOT_DIR=$(mktemp -d)
output=$("$AGENT_LOOP" --dir "$NOBOOT_DIR" --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
assert_not_contains "no boot file = no boot line" "$output" "boot:"
rm -rf "$NOBOOT_DIR"

# Test: task file boot directive takes precedence
cat > "$BOOT_DIR/tasks-with-boot.md" <<'MD'
<!-- boot: custom-boot.md -->
## Test
- Say hello
MD
echo "Custom boot content." > "$BOOT_DIR/custom-boot.md"
output=$("$AGENT_LOOP" --dir "$BOOT_DIR" --dry-run "$BOOT_DIR/tasks-with-boot.md" 2>&1)
assert_contains "task file boot directive shown" "$output" "boot:"
assert_contains "task file boot uses custom path" "$output" "custom-boot.md"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
