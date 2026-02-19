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

# ============================================================
echo "=== Backoff function tests ==="

# Source the backoff_sleep function from agent-loop.sh
source <(sed -n '/^backoff_sleep()/,/^}/p' "$AGENT_LOOP")

# Test: backoff_sleep returns a number > 0
result=$(backoff_sleep 1 false)
if [[ "$result" -gt 0 && "$result" -le 63 ]]; then
    echo "  PASS: backoff_sleep attempt 1 returns valid delay ($result)"
    ((pass++)) || true
else
    echo "  FAIL: backoff_sleep attempt 1 returned '$result'"
    ((fail++)) || true
fi

# Test: backoff_sleep attempt 3 is larger than attempt 1 base
result3=$(backoff_sleep 3 false)
if [[ "$result3" -ge 8 ]]; then
    echo "  PASS: backoff_sleep attempt 3 has higher base ($result3)"
    ((pass++)) || true
else
    echo "  FAIL: backoff_sleep attempt 3 too low ($result3)"
    ((fail++)) || true
fi

# Test: rate_limit doubles the delay
result_rl=$(backoff_sleep 1 true)
if [[ "$result_rl" -ge 4 ]]; then
    echo "  PASS: rate_limit backoff is doubled ($result_rl)"
    ((pass++)) || true
else
    echo "  FAIL: rate_limit backoff not doubled ($result_rl)"
    ((fail++)) || true
fi

# ============================================================
echo "=== Error classification tests ==="

# Source the classify_error function
source <(sed -n '/^classify_error()/,/^}/p' "$AGENT_LOOP")

# Create temp log files with known error patterns
CLASSIFY_DIR=$(mktemp -d)

echo "Error 429 Too Many Requests" > "$CLASSIFY_DIR/rate.log"
result=$(classify_error "$CLASSIFY_DIR/rate.log")
assert_contains "429 classified as rate_limit" "$result" "rate_limit"

echo "Error: context_length exceeded" > "$CLASSIFY_DIR/ctx.log"
result=$(classify_error "$CLASSIFY_DIR/ctx.log")
assert_contains "context_length classified as context_overflow" "$result" "context_overflow"

echo "Error 401 Unauthorized" > "$CLASSIFY_DIR/auth.log"
result=$(classify_error "$CLASSIFY_DIR/auth.log")
assert_contains "401 classified as auth" "$result" "auth"

echo "Connection timed out after 30s" > "$CLASSIFY_DIR/timeout.log"
result=$(classify_error "$CLASSIFY_DIR/timeout.log")
assert_contains "timeout classified as timeout" "$result" "timeout"

echo "Something went wrong" > "$CLASSIFY_DIR/unknown.log"
result=$(classify_error "$CLASSIFY_DIR/unknown.log")
assert_contains "generic error classified as unknown" "$result" "unknown"

rm -rf "$CLASSIFY_DIR"

# ============================================================
echo "=== Model failover tests ==="

# Test: --fallback-model appears in --help
output=$("$AGENT_LOOP" --help 2>&1)
assert_contains "--help includes --fallback-model" "$output" "--fallback-model"

# Test: --fallback-model without value fails
assert_fail "--fallback-model without value" "$AGENT_LOOP" --fallback-model

# Test: --fallback-model with value + dry-run works
output=$("$AGENT_LOOP" --model opus --fallback-model sonnet --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
assert_contains "dry-run with fallback shows model" "$output" "opus"

# ============================================================
echo "=== Interrupt resume tests ==="

# Test: 'interrupted' status is recognized in --status output
INT_DIR=$(mktemp -d)
mkdir -p "$INT_DIR/.agent-loop/logs"
TASK_MD="$INT_DIR/tasks.md"
cat > "$TASK_MD" <<'MD'
## Test
- Say hello
- Say goodbye
MD
HASH=$(sha256sum "$TASK_MD" | cut -d' ' -f1)
cat > "$INT_DIR/.agent-loop/state.json" <<STATEJSON
{
  "task_file": "$TASK_MD",
  "task_file_hash": "$HASH",
  "started_at": "2026-01-01T00:00:00Z",
  "tasks": [
    {
      "index": 1,
      "group": "Test",
      "task": "Say hello",
      "status": "interrupted",
      "session_id": null,
      "jj_change": null,
      "log": "001-test--say-hello.log",
      "attempts": 0,
      "interrupted_at": "2026-01-01T00:01:00Z",
      "partial_context": "I was about to create the file..."
    },
    {
      "index": 2,
      "group": "Test",
      "task": "Say goodbye",
      "status": "pending",
      "session_id": null,
      "jj_change": null,
      "log": "002-test--say-goodbye.log",
      "attempts": 0
    }
  ]
}
STATEJSON

# Test: --status shows interrupted task as INT
output=$("$AGENT_LOOP" --dir "$INT_DIR" --status 2>&1)
assert_contains "status shows interrupted task" "$output" "INT"

rm -rf "$INT_DIR"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
