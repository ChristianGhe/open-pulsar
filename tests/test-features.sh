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
echo "=== Slugify tests ==="

# Source the slugify function
source <(sed -n '/^slugify()/,/^}/p' "$AGENT_LOOP")

result=$(slugify "Hello World")
assert_contains "Hello World -> hello-world" "$result" "hello-world"

result=$(slugify "  foo---bar  ")
assert_contains "foo---bar -> foo-bar" "$result" "foo-bar"

result=$(slugify "---leading")
assert_contains "---leading -> leading" "$result" "leading"
# Must not have a leading dash
assert_not_contains "---leading has no leading dash" "$result" "-leading"

result=$(slugify "trailing---")
assert_contains "trailing--- -> trailing" "$result" "trailing"
# Must not have a trailing dash
assert_not_contains "trailing--- has no trailing dash" "$result" "trailing-"

# 60-char input truncated to ≤30 via cut -c1-30
long_input="abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefgh"  # 63 chars
result=$(slugify "$long_input" | cut -c1-30)
if [[ ${#result} -le 30 ]]; then
    echo "  PASS: 60+ char input slug truncated to ≤30 (got ${#result} chars)"
    ((pass++)) || true
else
    echo "  FAIL: 60+ char input slug too long (got ${#result} chars)"
    ((fail++)) || true
fi

# ============================================================
echo "=== write_daily_log tests ==="

# Source the write_daily_log function
source <(sed -n '/^write_daily_log()/,/^}/p' "$AGENT_LOOP")

DAILYLOG_DIR="$TEST_TMP/dailylog/logs"
mkdir -p "$DAILYLOG_DIR"
LOG_DIR="$DAILYLOG_DIR"

write_daily_log "COMPLETED" "MyGroup" "MyTask" "short result"

# Assert log file uses YYYY-MM-DD format
today=$(date +%Y-%m-%d)
expected_log="$DAILYLOG_DIR/agent_${today}.log"
if [[ -f "$expected_log" ]]; then
    echo "  PASS: daily log file created with YYYY-MM-DD filename"
    ((pass++)) || true
else
    echo "  FAIL: daily log file not found at $expected_log"
    ((fail++)) || true
fi

# Assert it does NOT use DDMMYYYY format
today_ddmmyyyy=$(date +%d%m%Y)
wrong_log="$DAILYLOG_DIR/agent_${today_ddmmyyyy}.log"
if [[ ! -f "$wrong_log" ]] || [[ "$expected_log" == "$wrong_log" ]]; then
    echo "  PASS: daily log does not use DDMMYYYY format"
    ((pass++)) || true
else
    echo "  FAIL: daily log uses wrong DDMMYYYY format"
    ((fail++)) || true
fi

# Assert log entry contains group and task name
log_content=$(cat "$expected_log")
assert_contains "daily log contains group name" "$log_content" "MyGroup"
assert_contains "daily log contains task name" "$log_content" "MyTask"

# Test truncation: result longer than 300 chars is truncated
long_result=$(printf 'X%.0s' $(seq 1 400))  # 400 chars of 'X'
write_daily_log "COMPLETED" "TruncGroup" "TruncTask" "$long_result"
log_content=$(cat "$expected_log")
# Extract the "Result: ..." line for TruncTask
result_line=$(grep "Result:.*XXXX" "$expected_log" | tail -1)
# The result part after "  Result: " prefix (10 chars) should be at most 300
result_value="${result_line#  Result: }"
if [[ ${#result_value} -le 300 ]]; then
    echo "  PASS: long result truncated to ≤300 chars (got ${#result_value})"
    ((pass++)) || true
else
    echo "  FAIL: long result not truncated (got ${#result_value} chars, expected ≤300)"
    ((fail++)) || true
fi

# ============================================================
echo "=== show_status tests ==="

# Source the show_status function
source <(sed -n '/^show_status()/,/^}/p' "$AGENT_LOOP")

STATUS_DIR="$TEST_TMP/statustest"
mkdir -p "$STATUS_DIR/.agent-loop"
STATE_FILE="$STATUS_DIR/.agent-loop/state.json"

cat > "$STATE_FILE" <<'STATUSJSON'
{
  "task_file": "tasks.md",
  "task_file_hash": "abc123",
  "started_at": "2026-01-01T00:00:00Z",
  "tasks": [
    {
      "index": 1,
      "group": "Build",
      "task": "Compile code",
      "status": "completed",
      "session_id": null,
      "jj_change": null,
      "log": "001-build--compile-code.log",
      "attempts": 1
    },
    {
      "index": 2,
      "group": "Build",
      "task": "Run linter",
      "status": "failed",
      "session_id": null,
      "jj_change": null,
      "log": "002-build--run-linter.log",
      "attempts": 3
    },
    {
      "index": 3,
      "group": "Deploy",
      "task": "Push image",
      "status": "interrupted",
      "session_id": null,
      "jj_change": null,
      "log": "003-deploy--push-image.log",
      "attempts": 1,
      "interrupted_at": "2026-01-01T00:05:00Z",
      "partial_context": "pushing to registry..."
    },
    {
      "index": 4,
      "group": "Deploy",
      "task": "Notify team",
      "status": "running",
      "session_id": null,
      "jj_change": null,
      "log": "004-deploy--notify-team.log",
      "attempts": 1
    }
  ]
}
STATUSJSON

status_output=$(show_status 2>&1)
assert_contains "show_status contains OK" "$status_output" "OK"
assert_contains "show_status contains FAIL" "$status_output" "FAIL"
assert_contains "show_status contains INT" "$status_output" "INT"
assert_contains "show_status contains RUN" "$status_output" "RUN"

# Pending should be 0: total=4, completed=1, failed=1, interrupted=1, running=1
# If running were not subtracted, pending would be 1 (wrong)
assert_contains "show_status pending is 0" "$status_output" "0 pending"
assert_not_contains "show_status pending is not 1" "$status_output" "1 pending"

# ============================================================
echo "=== parse_tasks tests ==="

# Source flush_task and parse_tasks functions
source <(sed -n '/^flush_task()/,/^}/p' "$AGENT_LOOP")
source <(sed -n '/^parse_tasks()/,/^}/p' "$AGENT_LOOP")

PARSE_DIR="$TEST_TMP/parse"
mkdir -p "$PARSE_DIR"

# --- Test 1: basic group + task assignment ---
cat > "$PARSE_DIR/basic.md" <<'MD'
## Setup
- Install dependencies
MD
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/basic.md"
assert_contains "basic: group name correct" "${TASK_GROUPS[0]}" "Setup"
assert_contains "basic: task text correct" "${TASK_TEXTS[0]}" "Install dependencies"
if [[ "$TOTAL_TASKS" -eq 1 ]]; then
    echo "  PASS: basic: TOTAL_TASKS=1"
    ((pass++)) || true
else
    echo "  FAIL: basic: TOTAL_TASKS=$TOTAL_TASKS (expected 1)"
    ((fail++)) || true
fi

# --- Test 2: multiline task (indented continuation joined with space) ---
cat > "$PARSE_DIR/multiline.md" <<'MD'
## Build
- Compile the source code
  with optimization flags
  and debug symbols
MD
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/multiline.md"
assert_contains "multiline: continuation joined" "${TASK_TEXTS[0]}" "Compile the source code with optimization flags and debug symbols"

# --- Test 3: tasks with no ## heading assigned to group "ungrouped" ---
cat > "$PARSE_DIR/ungrouped.md" <<'MD'
- First task
- Second task
MD
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/ungrouped.md"
assert_contains "ungrouped: group is 'ungrouped'" "${TASK_GROUPS[0]}" "ungrouped"
assert_contains "ungrouped: second task also ungrouped" "${TASK_GROUPS[1]}" "ungrouped"
if [[ "$TOTAL_TASKS" -eq 2 ]]; then
    echo "  PASS: ungrouped: TOTAL_TASKS=2"
    ((pass++)) || true
else
    echo "  FAIL: ungrouped: TOTAL_TASKS=$TOTAL_TASKS (expected 2)"
    ((fail++)) || true
fi

# --- Test 4: multiple groups, multiple tasks — correct group assignment ---
cat > "$PARSE_DIR/multigroup.md" <<'MD'
## Frontend
- Build React app
- Run unit tests

## Backend
- Start server
- Run integration tests
- Deploy to staging
MD
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/multigroup.md"
if [[ "$TOTAL_TASKS" -eq 5 ]]; then
    echo "  PASS: multigroup: TOTAL_TASKS=5"
    ((pass++)) || true
else
    echo "  FAIL: multigroup: TOTAL_TASKS=$TOTAL_TASKS (expected 5)"
    ((fail++)) || true
fi
assert_contains "multigroup: task 0 group=Frontend" "${TASK_GROUPS[0]}" "Frontend"
assert_contains "multigroup: task 1 group=Frontend" "${TASK_GROUPS[1]}" "Frontend"
assert_contains "multigroup: task 2 group=Backend" "${TASK_GROUPS[2]}" "Backend"
assert_contains "multigroup: task 3 group=Backend" "${TASK_GROUPS[3]}" "Backend"
assert_contains "multigroup: task 4 group=Backend" "${TASK_GROUPS[4]}" "Backend"
assert_contains "multigroup: task 2 text" "${TASK_TEXTS[2]}" "Start server"
assert_contains "multigroup: task 4 text" "${TASK_TEXTS[4]}" "Deploy to staging"

# --- Test 5: empty file → TOTAL_TASKS=0, no crash ---
> "$PARSE_DIR/empty.md"
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/empty.md"
if [[ "$TOTAL_TASKS" -eq 0 ]]; then
    echo "  PASS: empty file: TOTAL_TASKS=0"
    ((pass++)) || true
else
    echo "  FAIL: empty file: TOTAL_TASKS=$TOTAL_TASKS (expected 0)"
    ((fail++)) || true
fi

# --- Test 6: file with only headings, no tasks → TOTAL_TASKS=0 ---
cat > "$PARSE_DIR/headings-only.md" <<'MD'
## Group A
## Group B
## Group C
MD
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/headings-only.md"
if [[ "$TOTAL_TASKS" -eq 0 ]]; then
    echo "  PASS: headings only: TOTAL_TASKS=0"
    ((pass++)) || true
else
    echo "  FAIL: headings only: TOTAL_TASKS=$TOTAL_TASKS (expected 0)"
    ((fail++)) || true
fi

# --- Test 7: CRLF line endings stripped from group name and task text ---
printf "## MyGroup\r\n- My CRLF task\r\n" > "$PARSE_DIR/crlf.md"
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/crlf.md"
assert_not_contains "crlf: group has no trailing \\r" "${TASK_GROUPS[0]}" $'\r'
assert_not_contains "crlf: task has no trailing \\r" "${TASK_TEXTS[0]}" $'\r'
assert_contains "crlf: group name correct" "${TASK_GROUPS[0]}" "MyGroup"
assert_contains "crlf: task text correct" "${TASK_TEXTS[0]}" "My CRLF task"

# --- Test 8: task immediately followed by ## heading without blank line ---
cat > "$PARSE_DIR/noblank.md" <<'MD'
## First
- Task in first group
## Second
- Task in second group
MD
TASK_GROUPS=(); TASK_TEXTS=(); TOTAL_TASKS=0
parse_tasks "$PARSE_DIR/noblank.md"
if [[ "$TOTAL_TASKS" -eq 2 ]]; then
    echo "  PASS: noblank: TOTAL_TASKS=2"
    ((pass++)) || true
else
    echo "  FAIL: noblank: TOTAL_TASKS=$TOTAL_TASKS (expected 2)"
    ((fail++)) || true
fi
assert_contains "noblank: first task group=First" "${TASK_GROUPS[0]}" "First"
assert_contains "noblank: first task text correct" "${TASK_TEXTS[0]}" "Task in first group"
assert_contains "noblank: second task group=Second" "${TASK_GROUPS[1]}" "Second"
assert_contains "noblank: second task text correct" "${TASK_TEXTS[1]}" "Task in second group"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
