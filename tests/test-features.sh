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

# Setup temp dir for all tests
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
BOOT_DIR="$TEST_TMP/boot"
mkdir -p "$BOOT_DIR"

# Test: boot.md in .agent-loop/ is detected in dry-run banner
mkdir -p "$BOOT_DIR/.agent-loop"
echo "This is a test project." > "$BOOT_DIR/.agent-loop/boot.md"
output=$("$AGENT_LOOP" --dir "$BOOT_DIR" --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
assert_contains "boot.md shown in banner" "$output" "boot:"

# Test: no boot file = no boot line in banner
NOBOOT_DIR="$TEST_TMP/noboot"
mkdir -p "$NOBOOT_DIR"
output=$("$AGENT_LOOP" --dir "$NOBOOT_DIR" --dry-run "$SCRIPT_DIR/minimal-tasks.md" 2>&1)
assert_not_contains "no boot file = no boot line" "$output" "boot:"

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
CLASSIFY_DIR="$TEST_TMP/classify"
mkdir -p "$CLASSIFY_DIR"

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

echo "ECONNREFUSED: connection refused" > "$CLASSIFY_DIR/network.log"
result=$(classify_error "$CLASSIFY_DIR/network.log")
assert_contains "ECONNREFUSED classified as network" "$result" "network"

echo "Something went wrong" > "$CLASSIFY_DIR/unknown.log"
result=$(classify_error "$CLASSIFY_DIR/unknown.log")
assert_contains "generic error classified as unknown" "$result" "unknown"

# cleaned up by EXIT trap

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
INT_DIR="$TEST_TMP/interrupt"
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

# cleaned up by EXIT trap

# ============================================================
echo "=== Context compaction tests ==="

# Source the token extraction function
source <(sed -n '/^extract_token_usage()/,/^}/p' "$AGENT_LOOP")

# Test: extract_token_usage parses Claude JSON output
COMPACT_DIR="$TEST_TMP/compact"
mkdir -p "$COMPACT_DIR"
cat > "$COMPACT_DIR/output.json" <<'JSON'
{
  "type": "result",
  "session_id": "test-123",
  "usage": {
    "input_tokens": 1000,
    "cache_creation_input_tokens": 500,
    "cache_read_input_tokens": 2000,
    "output_tokens": 300
  },
  "modelUsage": {
    "claude-opus-4-6": {
      "inputTokens": 1000,
      "outputTokens": 300,
      "contextWindow": 200000
    }
  }
}
JSON

result=$(extract_token_usage "$COMPACT_DIR/output.json")
tokens=$(echo "$result" | cut -d: -f1)
window=$(echo "$result" | cut -d: -f2)

if [[ "$tokens" -eq 3800 ]]; then
    echo "  PASS: token count extracted correctly ($tokens)"
    ((pass++)) || true
else
    echo "  FAIL: token count wrong (got $tokens, expected 3800)"
    ((fail++)) || true
fi

if [[ "$window" -eq 200000 ]]; then
    echo "  PASS: context window extracted correctly ($window)"
    ((pass++)) || true
else
    echo "  FAIL: context window wrong (got $window, expected 200000)"
    ((fail++)) || true
fi

# cleaned up by EXIT trap

# ============================================================
echo "=== Messaging tests ==="

MSG_DIR="$TEST_TMP/messaging"
mkdir -p "$MSG_DIR"

# Test: --help includes --send-message and --messages
output=$("$AGENT_LOOP" --help 2>&1)
assert_contains "--help includes --send-message" "$output" "--send-message"
assert_contains "--help includes --messages" "$output" "--messages"

# Test: --send-message without value fails
assert_fail "--send-message without value fails" "$AGENT_LOOP" --send-message

# Test: --send-message queues a message in inbox.txt and messages.jsonl
output=$("$AGENT_LOOP" --dir "$MSG_DIR" --send-message "What is the status of the API?" 2>&1)
assert_contains "--send-message reports queued" "$output" "Message queued"

# Verify inbox.txt was created and contains the message
if [[ -f "$MSG_DIR/.agent-loop/inbox.txt" ]]; then
    echo "  PASS: inbox.txt created"
    ((pass++)) || true
else
    echo "  FAIL: inbox.txt not created"
    ((fail++)) || true
fi

inbox_content=$(cat "$MSG_DIR/.agent-loop/inbox.txt" 2>/dev/null || echo "")
assert_contains "inbox.txt contains the message" "$inbox_content" "What is the status of the API?"

# Verify messages.jsonl was created with correct role
if [[ -f "$MSG_DIR/.agent-loop/messages.jsonl" ]]; then
    echo "  PASS: messages.jsonl created"
    ((pass++)) || true
else
    echo "  FAIL: messages.jsonl not created"
    ((fail++)) || true
fi

msg_role=$(jq -r '.role' "$MSG_DIR/.agent-loop/messages.jsonl" 2>/dev/null || echo "")
assert_contains "messages.jsonl has role=user" "$msg_role" "user"

msg_text=$(jq -r '.text' "$MSG_DIR/.agent-loop/messages.jsonl" 2>/dev/null || echo "")
assert_contains "messages.jsonl has correct text" "$msg_text" "What is the status of the API?"

# Test: --messages shows message thread
output=$("$AGENT_LOOP" --dir "$MSG_DIR" --messages 2>&1)
assert_contains "--messages shows You label" "$output" "You"
assert_contains "--messages shows the message text" "$output" "What is the status of the API?"

# Test: --messages with no messages shows no-messages notice
EMPTY_MSG_DIR="$TEST_TMP/empty-messaging"
mkdir -p "$EMPTY_MSG_DIR"
output=$("$AGENT_LOOP" --dir "$EMPTY_MSG_DIR" --messages 2>&1)
assert_contains "--messages with no messages shows notice" "$output" "No messages"

# Test: multiple messages accumulate in inbox and history
"$AGENT_LOOP" --dir "$MSG_DIR" --send-message "Second question" >/dev/null 2>&1
inbox_lines=$(wc -l < "$MSG_DIR/.agent-loop/inbox.txt" 2>/dev/null || echo "0")
if [[ "$inbox_lines" -ge 2 ]]; then
    echo "  PASS: multiple messages accumulate in inbox ($inbox_lines lines)"
    ((pass++)) || true
else
    echo "  FAIL: expected 2+ inbox lines, got $inbox_lines"
    ((fail++)) || true
fi

history_lines=$(wc -l < "$MSG_DIR/.agent-loop/messages.jsonl" 2>/dev/null || echo "0")
if [[ "$history_lines" -ge 2 ]]; then
    echo "  PASS: multiple messages accumulate in history ($history_lines lines)"
    ((pass++)) || true
else
    echo "  FAIL: expected 2+ history lines, got $history_lines"
    ((fail++)) || true
fi

# cleaned up by EXIT trap

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
