# OpenClaw-Inspired Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 6 features inspired by openclaw/openclaw to agent-loop.sh: boot file, exponential backoff, error pre-classification, model failover, graceful interrupt with resume context, and context compaction.

**Architecture:** All changes go into the single `agent-loop.sh` file (~650 lines today, ~1000 after). New functions are added in the appropriate section (globals at top, utility functions mid-file, execution logic near `execute_tasks`). A new test file `tests/test-features.sh` covers all 6 features using the existing assert pattern.

**Tech Stack:** Bash 4+, jq, Claude CLI JSON output

**Design doc:** `docs/plans/2026-02-19-openclaw-inspired-features-design.md`

---

### Task 1: Boot/Bootstrap File

**Files:**
- Modify: `agent-loop.sh:24-28` (SYSTEM_PROMPT area), `agent-loop.sh:42-48` (show_banner), `agent-loop.sh:110-149` (parse_tasks), `agent-loop.sh:611-647` (main)
- Create: `tests/test-features.sh`

**Step 1: Write the failing tests**

Create `tests/test-features.sh` with the boot file tests:

```bash
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
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-features.sh`
Expected: FAIL — no boot file support exists yet.

**Step 3: Add the `BOOT_FILE` global and `load_boot_file` function**

Add after `SYSTEM_PROMPT` block (after line 28):

```bash
BOOT_FILE=""

load_boot_file() {
    local boot_path=""

    # Priority 1: task file directive (<!-- boot: path -->)
    if [[ -n "${TASK_FILE:-}" ]]; then
        local directive
        directive=$(grep -m1 '^<!-- boot:' "$TASK_FILE" 2>/dev/null || echo "")
        if [[ "$directive" =~ ^\<!--\ boot:\ (.+)\ --\>$ ]]; then
            local rel_path="${BASH_REMATCH[1]}"
            # Resolve relative to task file's directory
            local task_dir
            task_dir="$(cd "$(dirname "$TASK_FILE")" && pwd)"
            if [[ -f "$task_dir/$rel_path" ]]; then
                boot_path="$task_dir/$rel_path"
            elif [[ -f "$TARGET_DIR/$rel_path" ]]; then
                boot_path="$TARGET_DIR/$rel_path"
            fi
        fi
    fi

    # Priority 2: .agent-loop/boot.md in target dir
    if [[ -z "$boot_path" && -f "$TARGET_DIR/.agent-loop/boot.md" ]]; then
        boot_path="$TARGET_DIR/.agent-loop/boot.md"
    fi

    if [[ -n "$boot_path" ]]; then
        BOOT_FILE="$boot_path"
        local boot_content
        boot_content=$(cat "$boot_path")
        SYSTEM_PROMPT="$SYSTEM_PROMPT

PROJECT CONTEXT:
$boot_content"
    fi
}
```

**Step 4: Update `show_banner` to display boot file**

In `show_banner` (line 42-48), add after the target dir line:

```bash
    if [[ -n "$BOOT_FILE" ]]; then
        echo -e "  ${BLUE}boot:${NC} $BOOT_FILE"
    fi
```

**Step 5: Call `load_boot_file` in `main`**

In `main()`, after `parse_tasks "$TASK_FILE"` (line 633) and before the dry-run check, add:

```bash
    load_boot_file
```

Move `show_banner` call to after `load_boot_file` so it can display the boot file path. The new order in `main()`:

```bash
    check_dependencies
    parse_tasks "$TASK_FILE"
    load_boot_file
    show_banner

    if $DRY_RUN; then
```

Note: For `--reset` and `--status` paths (lines 622-630), `show_banner` is called before `check_dependencies`, so move those to also call `show_banner` early, or just keep the existing early `show_banner` for those paths and add a second banner display. Simplest: keep `show_banner` at line 620 for reset/status paths, and also call it after `load_boot_file` for the normal execution path. Guard against double-display by removing the line 620 call and placing it in each branch.

Restructure `main()`:

```bash
main() {
    parse_args "$@"

    TARGET_DIR="${TARGET_DIR:-$(pwd)}"
    STATE_DIR="$TARGET_DIR/.agent-loop"
    STATE_FILE="$STATE_DIR/state.json"
    LOG_DIR="$STATE_DIR/logs"

    if $DO_RESET; then
        show_banner
        reset_state
        exit 0
    fi

    if $DO_STATUS; then
        show_banner
        show_status
        exit 0
    fi

    check_dependencies
    parse_tasks "$TASK_FILE"
    load_boot_file
    show_banner

    if $DRY_RUN; then
        show_parsed_tasks
        exit 0
    fi

    init_state
    ensure_jj
    echo "Executing $TOTAL_TASKS tasks from $TASK_FILE (model: $MODEL)"
    execute_tasks
    show_summary
}
```

**Step 6: Run tests to verify they pass**

Run: `bash tests/test-features.sh`
Expected: PASS — all boot file tests green.

**Step 7: Also run existing tests**

Run: `bash tests/test-dir-flag.sh`
Expected: PASS — no regressions.

**Step 8: Commit**

```bash
git add agent-loop.sh tests/test-features.sh
git commit -m "feat: add boot/bootstrap file support

Load project-specific context from .agent-loop/boot.md or a
<!-- boot: path --> directive in the task file. Appends content
to the system prompt so Claude has domain knowledge."
```

---

### Task 2: Exponential Backoff with Jitter

**Files:**
- Modify: `agent-loop.sh` (new function after jj functions, retry loop in `execute_tasks`)
- Modify: `tests/test-features.sh` (add backoff tests)

**Step 1: Add backoff tests to `tests/test-features.sh`**

Append before the final results summary:

```bash
# ============================================================
echo "=== Backoff function tests ==="

# Source the script to test the function directly
# We need to extract just the function — use a subshell trick
# Create a helper that sources agent-loop.sh functions without running main
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
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-features.sh`
Expected: FAIL — `backoff_sleep` function not found.

**Step 3: Implement `backoff_sleep` function**

Add after `jj_abandon_change` (after line 293):

```bash
backoff_sleep() {
    local attempt="$1"
    local is_rate_limit="${2:-false}"

    local base=$((1 << attempt))  # 2^attempt
    local jitter=$((RANDOM % 4))  # 0-3
    local delay=$((base + jitter))

    if [[ "$is_rate_limit" == "true" ]]; then
        delay=$((delay * 2))
    fi

    # Cap at 60 seconds
    if [[ $delay -gt 60 ]]; then
        delay=60
    fi

    echo "$delay"
}
```

**Step 4: Integrate backoff into the retry loop in `execute_tasks`**

In the retry loop (around line 434), after the "retry: attempt N" message and before calling `run_claude`, add:

```bash
                local wait_seconds
                wait_seconds=$(backoff_sleep "$attempt" false)
                echo -e "  ${YELLOW}waiting ${wait_seconds}s before retry...${NC}"
                sleep "$wait_seconds"
```

The `false` for `is_rate_limit` is a placeholder — it will be replaced in Task 3 when error classification is added.

**Step 5: Run tests to verify they pass**

Run: `bash tests/test-features.sh`
Expected: PASS

**Step 6: Run existing tests for regressions**

Run: `bash tests/test-dir-flag.sh`
Expected: PASS

**Step 7: Commit**

```bash
git add agent-loop.sh tests/test-features.sh
git commit -m "feat: add exponential backoff with jitter for retries

Wait 2^attempt + random(0-3) seconds between retries, capped at
60s. Rate-limit errors get doubled delay. Prevents hammering the
API on transient failures."
```

---

### Task 3: Error Pre-Classification

**Files:**
- Modify: `agent-loop.sh` (new `classify_error` function, modify retry logic in `execute_tasks`)
- Modify: `tests/test-features.sh`

**Step 1: Add classification tests to `tests/test-features.sh`**

Append before final results:

```bash
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
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-features.sh`
Expected: FAIL — `classify_error` not found.

**Step 3: Implement `classify_error` function**

Add after `backoff_sleep`:

```bash
classify_error() {
    local log_file="$1"

    local error_tail
    error_tail=$(tail -c 3000 "$log_file" 2>/dev/null || echo "")

    if echo "$error_tail" | grep -qiE '429|rate_limit|rate limit|too many requests'; then
        echo "rate_limit"
    elif echo "$error_tail" | grep -qiE 'context_length|token limit|maximum context|context window'; then
        echo "context_overflow"
    elif echo "$error_tail" | grep -qiE '401|authentication|unauthorized|invalid.*api.*key'; then
        echo "auth"
    elif echo "$error_tail" | grep -qiE 'timeout|SIGTERM|timed out|deadline exceeded'; then
        echo "timeout"
    elif echo "$error_tail" | grep -qiE 'ECONNREFUSED|ENOTFOUND|DNS|network|connection refused'; then
        echo "network"
    else
        echo "unknown"
    fi
}
```

**Step 4: Rewire the retry logic in `execute_tasks`**

Replace the failure handling block (lines 462-483) with classification-aware logic. The new block after a failed `run_claude` call:

```bash
            echo -e "  ${RED}failed${NC} on attempt $attempt"

            # Classify the error
            local error_class
            error_class=$(classify_error "$LOG_DIR/$log_name")
            echo -e "  ${YELLOW}error class:${NC} $error_class"

            # Handle based on classification
            if [[ "$error_class" == "auth" ]]; then
                echo -e "  ${RED}Authentication error — not retryable.${NC}"
                break
            fi

            if [[ "$error_class" == "context_overflow" ]]; then
                echo -e "  ${YELLOW}Context overflow — starting fresh session.${NC}"
                session_id=""
                hint="Previous attempt hit context limit. Be more concise."
                # Still counts as an attempt, continue to retry
            fi

            if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
                local is_rate_limit=false
                [[ "$error_class" == "rate_limit" ]] && is_rate_limit=true

                # Backoff before retry
                local wait_seconds
                wait_seconds=$(backoff_sleep "$attempt" "$is_rate_limit")
                echo -e "  ${YELLOW}waiting ${wait_seconds}s before retry...${NC}"
                sleep "$wait_seconds"

                if [[ "$error_class" == "unknown" ]]; then
                    # AI-driven analysis only for unclassified errors
                    echo -e "  ${YELLOW}analyzing failure...${NC}"
                    local analysis
                    analysis=$(analyze_failure "$task" "$log_name")
                    local should_retry
                    should_retry=$(echo "$analysis" | jq -r '.retry' 2>/dev/null || echo "false")
                    local reason
                    reason=$(echo "$analysis" | jq -r '.reason' 2>/dev/null || echo "")
                    hint=$(echo "$analysis" | jq -r '.hint' 2>/dev/null || echo "")

                    echo "  analysis: $reason"

                    if [[ "$should_retry" != "true" ]]; then
                        echo -e "  ${YELLOW}AI decided not to retry. Moving on.${NC}"
                        break
                    fi

                    echo "  hint: $hint"
                elif [[ "$error_class" == "rate_limit" || "$error_class" == "network" || "$error_class" == "timeout" ]]; then
                    hint="Previous attempt failed with $error_class. Retrying."
                fi
            fi
```

Also remove the now-redundant standalone backoff call added in Task 2 (the backoff is now inside this block).

**Step 5: Run tests to verify they pass**

Run: `bash tests/test-features.sh`
Expected: PASS

**Step 6: Run existing tests for regressions**

Run: `bash tests/test-dir-flag.sh`
Expected: PASS

**Step 7: Commit**

```bash
git add agent-loop.sh tests/test-features.sh
git commit -m "feat: add error pre-classification before AI analysis

Classify errors locally (rate_limit, context_overflow, auth,
timeout, network) before calling Haiku. Only unknown errors
go through AI analysis. Saves API cost and handles common
failures faster."
```

---

### Task 4: Model Failover

**Files:**
- Modify: `agent-loop.sh` (globals, `parse_args`, `usage`, retry loop in `execute_tasks`)
- Modify: `tests/test-features.sh`

**Step 1: Add failover tests to `tests/test-features.sh`**

Append before final results:

```bash
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
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-features.sh`
Expected: FAIL — `--fallback-model` not recognized.

**Step 3: Add `FALLBACK_MODEL` global and `ORIGINAL_MODEL`**

At top of file (after line 6, the `MODEL` line):

```bash
FALLBACK_MODEL=""
ORIGINAL_MODEL=""
```

**Step 4: Add `--fallback-model` to `parse_args`**

In `parse_args` case statement, after the `--model` case (after line 548):

```bash
            --fallback-model)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --fallback-model requires a model name" >&2
                    exit 1
                fi
                FALLBACK_MODEL="$2"
                shift 2
                ;;
```

**Step 5: Add `--fallback-model` to `usage`**

In the `usage()` heredoc, after the `--model` line:

```
  --fallback-model <m>  Fallback model on rate limit/timeout (optional)
```

**Step 6: Save original model in `main`**

In `main()`, after `parse_args "$@"`:

```bash
    ORIGINAL_MODEL="$MODEL"
```

**Step 7: Add failover logic to retry loop**

In the error handling block in `execute_tasks` (the block rewritten in Task 3), after backoff and before the AI analysis, add failover for rate_limit/timeout:

```bash
                # Model failover for rate_limit and timeout
                if [[ -n "$FALLBACK_MODEL" && ("$error_class" == "rate_limit" || "$error_class" == "timeout") ]]; then
                    local old_model="$MODEL"
                    if [[ "$MODEL" == "$ORIGINAL_MODEL" ]]; then
                        MODEL="$FALLBACK_MODEL"
                    else
                        MODEL="$ORIGINAL_MODEL"
                    fi
                    echo -e "  ${YELLOW}failover: switching from $old_model to $MODEL${NC}"
                fi
```

After each task completes (success or final failure), reset model:

```bash
        # Reset model after each task
        MODEL="$ORIGINAL_MODEL"
```

Add this line twice: after the `success=true; break` block (around line 459), and after the final failure block (around line 493).

**Step 8: Run tests to verify they pass**

Run: `bash tests/test-features.sh`
Expected: PASS

**Step 9: Run existing tests for regressions**

Run: `bash tests/test-dir-flag.sh`
Expected: PASS

**Step 10: Commit**

```bash
git add agent-loop.sh tests/test-features.sh
git commit -m "feat: add --fallback-model for automatic model failover

On rate_limit or timeout errors, swap to the fallback model.
Alternates between primary and fallback on consecutive failures.
Resets to original model after each task."
```

---

### Task 5: Graceful Interrupt with Resume Context

**Files:**
- Modify: `agent-loop.sh` (trap handler, `execute_tasks`, task status check)
- Modify: `tests/test-features.sh`

**Step 1: Add interrupt tests to `tests/test-features.sh`**

Append before final results:

```bash
# ============================================================
echo "=== Interrupt resume tests ==="

# Test: 'interrupted' status is recognized on resume (not skipped like completed, not stuck)
# We simulate by creating a state file with an interrupted task
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

# Test: --status shows interrupted task
output=$("$AGENT_LOOP" --dir "$INT_DIR" --status 2>&1)
assert_contains "status shows interrupted task" "$output" "INT"

rm -rf "$INT_DIR"
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-features.sh`
Expected: FAIL — `interrupted` status not handled in `show_status`.

**Step 3: Update `show_status` to handle `interrupted` status**

In `show_status` (line 90), update the jq format to handle the new status:

```bash
    jq -r '.tasks[] | "  [\(.status | if . == "completed" then "OK" elif . == "failed" then "FAIL" elif . == "interrupted" then "INT" else "..." end)] \(.group) > \(.task)"' "$STATE_FILE"
```

**Step 4: Update `execute_tasks` skip logic**

Change line 400 to NOT skip interrupted tasks:

```bash
        # Skip completed/failed tasks (interrupted tasks are re-attempted)
        if [[ "$status" == "completed" || "$status" == "failed" ]]; then
            continue
        fi
```

**Step 5: Add interrupted task context injection**

After the skip check and before the jj change creation, handle interrupted tasks:

```bash
        # If resuming an interrupted task, inject partial context as hint
        if [[ "$status" == "interrupted" ]]; then
            local partial
            partial=$(get_task_field "$i" "partial_context")
            if [[ -n "$partial" && "$partial" != "null" ]]; then
                hint="CONTEXT FROM INTERRUPTED ATTEMPT: $partial"
            fi
            # Reset attempts for interrupted tasks
            update_task_state "$i" "attempts" "0" raw
        fi
```

Note: `hint` needs to be declared before the attempt loop. Move its declaration to before the interrupted check. Also initialize it:

```bash
        local hint=""

        # If resuming an interrupted task...
        if [[ "$status" == "interrupted" ]]; then
            ...
        fi
```

And remove the `local hint=""` that's currently inside the attempt loop (line 429).

**Step 6: Enhance the trap handler to save interrupt context**

Replace the trap line (line 387) and add a helper. The trap needs access to the current task index and log, so use globals:

Add new globals at the top of `execute_tasks`:

```bash
    local _current_task_index=-1
    local _current_log_name=""
```

Set them at the start of each task iteration (after getting `log_name`):

```bash
        _current_task_index=$i
        _current_log_name="$log_name"
```

Replace the trap:

```bash
    trap '_handle_interrupt' INT TERM
```

Add `_handle_interrupt` as a new function before `execute_tasks`:

```bash
_handle_interrupt() {
    echo ""
    echo "Interrupted. Saving context..."

    if [[ -n "${_current_task_index:-}" && "${_current_task_index:-}" -ge 0 ]]; then
        local partial=""
        local log_path="$LOG_DIR/${_current_log_name}"
        if [[ -f "$log_path" ]]; then
            partial=$(tail -c 500 "$log_path" 2>/dev/null || echo "")
        fi

        update_task_state "$_current_task_index" "status" "interrupted"
        update_task_state "$_current_task_index" "interrupted_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ -n "$partial" ]]; then
            update_task_state "$_current_task_index" "partial_context" "$partial"
        fi
    fi

    echo "Progress saved. Resume by re-running the same command."
    exit 130
}
```

Since `_handle_interrupt` needs access to `_current_task_index`, `_current_log_name`, `LOG_DIR`, and `STATE_FILE`, and these are either globals or locals in `execute_tasks`, the function needs to be defined inside `execute_tasks` or use global variables. Simplest: promote `_current_task_index` and `_current_log_name` to global scope by declaring them before `execute_tasks` is called.

Add after the other globals at top of file:

```bash
_current_task_index=-1
_current_log_name=""
```

And in `execute_tasks`, assign to them (without `local`).

**Step 7: Remove old trap exit logic**

Remove the `interrupted` local variable and the `if $interrupted; then break; fi` / `if $interrupted; then exit 130; fi` blocks from `execute_tasks`, since the trap now handles exit directly.

**Step 8: Abandon jj change on interrupt**

In `_handle_interrupt`, before saving state, abandon the current jj change:

```bash
    if [[ -n "${_current_task_index:-}" && "${_current_task_index:-}" -ge 0 ]]; then
        local jj_change
        jj_change=$(get_task_field "$_current_task_index" "jj_change")
        jj_abandon_change "$jj_change"
        ...
    fi
```

**Step 9: Run tests to verify they pass**

Run: `bash tests/test-features.sh`
Expected: PASS

**Step 10: Run existing tests for regressions**

Run: `bash tests/test-dir-flag.sh`
Expected: PASS

**Step 11: Commit**

```bash
git add agent-loop.sh tests/test-features.sh
git commit -m "feat: save partial context on interrupt for smarter resume

On Ctrl+C, capture last 500 chars of output as partial_context
in state. Interrupted tasks are re-attempted on resume with
context from the previous partial run injected as a hint."
```

---

### Task 6: Context Compaction

**Files:**
- Modify: `agent-loop.sh` (new `extract_token_usage`, `compact_session` functions, modify `run_claude` to return token info, modify `execute_tasks` to track and trigger compaction)
- Modify: `tests/test-features.sh`

**Step 1: Add compaction tests to `tests/test-features.sh`**

Append before final results:

```bash
# ============================================================
echo "=== Context compaction tests ==="

# Source the token extraction function
source <(sed -n '/^extract_token_usage()/,/^}/p' "$AGENT_LOOP")

# Test: extract_token_usage parses Claude JSON output
COMPACT_DIR=$(mktemp -d)
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

rm -rf "$COMPACT_DIR"
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-features.sh`
Expected: FAIL — `extract_token_usage` not found.

**Step 3: Implement `extract_token_usage` function**

Add after `classify_error`:

```bash
extract_token_usage() {
    local json_file="$1"

    local input cache_create cache_read output context_window
    input=$(jq -r '.usage.input_tokens // 0' "$json_file" 2>/dev/null || echo 0)
    cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' "$json_file" 2>/dev/null || echo 0)
    cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' "$json_file" 2>/dev/null || echo 0)
    output=$(jq -r '.usage.output_tokens // 0' "$json_file" 2>/dev/null || echo 0)
    context_window=$(jq -r '[.modelUsage[]] | .[0].contextWindow // 200000' "$json_file" 2>/dev/null || echo 200000)

    local total=$((input + cache_create + cache_read + output))
    echo "${total}:${context_window}"
}
```

**Step 4: Implement `compact_session` function**

Add after `extract_token_usage`:

```bash
compact_session() {
    local session_id="$1"
    local model="$2"

    local summary_prompt="Summarize the work completed so far in this session concisely.
Include: files created/modified, key decisions made, current state of the task.
Be specific about file paths and function names. Keep it under 500 words."

    local claude_args=(
        -p
        --dangerously-skip-permissions
        --model "$model"
        --output-format json
        --resume "$session_id"
    )

    local result
    result=$(cd "$TARGET_DIR" && CLAUDECODE= claude "${claude_args[@]}" "$summary_prompt" 2>/dev/null) || true

    local summary
    summary=$(echo "$result" | jq -r '.result // empty' 2>/dev/null || echo "")

    if [[ -z "$summary" ]]; then
        summary="(compaction summary unavailable)"
    fi

    echo "$summary"
}
```

**Step 5: Add session token tracking globals**

Add at the top of file with other globals:

```bash
SESSION_TOKENS=0
CONTEXT_WINDOW=200000
COMPACTION_THRESHOLD=80  # percentage
```

**Step 6: Modify `run_claude` to output token info alongside session_id**

Currently `run_claude` echoes just the session_id. Change it to echo `session_id:tokens:context_window` so the caller can parse all three. Update the success path (around line 336-338):

```bash
    # Extract session_id and token usage from JSON output
    local new_session_id
    new_session_id=$(echo "$output" | jq -r '.session_id // empty' 2>/dev/null || echo "")

    local token_info
    token_info=$(extract_token_usage "$LOG_DIR/$log_file")

    echo "${new_session_id}:${token_info}"
    return 0
```

This outputs `session_id:tokens:context_window`.

**Step 7: Update `execute_tasks` to parse the new output format and track tokens**

Where `run_claude` output is captured (around line 449-460), change:

```bash
            local claude_output
            claude_output=$(run_claude "$task" "$session_id" "$log_name" "$hint")
            local run_exit=$?

            if [[ $run_exit -eq 0 && -n "$claude_output" ]]; then
                local new_session_id new_tokens new_window
                new_session_id=$(echo "$claude_output" | cut -d: -f1)
                new_tokens=$(echo "$claude_output" | cut -d: -f2)
                new_window=$(echo "$claude_output" | cut -d: -f3)

                session_id="$new_session_id"
                SESSION_TOKENS=$((SESSION_TOKENS + new_tokens))
                CONTEXT_WINDOW="${new_window:-200000}"

                update_task_state "$i" "status" "completed"
                update_task_state "$i" "session_id" "$session_id"
                update_task_state "$i" "attempts" "$attempt" raw
                echo -e "  ${GREEN}completed${NC} (session $session_id, ${SESSION_TOKENS} tokens used)"
                success=true
                break
            fi
```

**Step 8: Add compaction check between tasks**

After a task completes successfully and before the next iteration, add a compaction check. Place this after the `success=true; break` and its closing of the while loop, but before the next iteration of the for loop. Best location: right after the `done` of the while loop, inside the success branch:

```bash
        if $success; then
            # Check if compaction needed
            local usage_pct=$((SESSION_TOKENS * 100 / CONTEXT_WINDOW))
            if [[ $usage_pct -ge $COMPACTION_THRESHOLD && -n "$session_id" ]]; then
                echo -e "  ${YELLOW}compaction: context at ${usage_pct}%, summarizing session...${NC}"
                local summary
                summary=$(compact_session "$session_id" "$MODEL")
                # Next task gets fresh session with summary as context
                session_id=""
                SESSION_TOKENS=0
                # Store summary to inject into next task's prompt
                COMPACTION_SUMMARY="$summary"
                echo -e "  ${YELLOW}compaction: fresh session ready with summary${NC}"
            fi
        fi
```

Add `COMPACTION_SUMMARY=""` to the globals at the top of the file.

**Step 9: Inject compaction summary into next task's prompt**

In `run_claude`, modify the prompt construction (around line 301-306) to prepend compaction context:

```bash
    local prompt="$task_text"
    if [[ -n "${COMPACTION_SUMMARY:-}" ]]; then
        prompt="CONTEXT FROM PREVIOUS SESSION:
$COMPACTION_SUMMARY

NEXT TASK: $task_text"
        COMPACTION_SUMMARY=""  # Clear after use
    fi
    if [[ -n "$hint" ]]; then
        prompt="$prompt

IMPORTANT HINT FROM PREVIOUS ATTEMPT: $hint"
    fi
```

**Step 10: Reset `SESSION_TOKENS` on new group**

Where `session_id` is reset on group change (around line 407):

```bash
        if [[ "$group" != "$current_group" ]]; then
            current_group="$group"
            session_id=""
            SESSION_TOKENS=0
        fi
```

**Step 11: Run tests to verify they pass**

Run: `bash tests/test-features.sh`
Expected: PASS

**Step 12: Run existing tests for regressions**

Run: `bash tests/test-dir-flag.sh`
Expected: PASS

**Step 13: Commit**

```bash
git add agent-loop.sh tests/test-features.sh
git commit -m "feat: add context compaction when session fills up

Track cumulative token usage per session from Claude JSON output.
When usage exceeds 80% of context window, summarize the session
and start fresh with summary injected as context. Prevents
degraded performance on long task groups."
```

---

### Task 7: Final Integration Test and Cleanup

**Files:**
- Modify: `agent-loop.sh` (update `usage()`, update VERSION)
- Modify: `tests/test-features.sh` (verify all tests pass together)
- Modify: `CLAUDE.md` (update commands section with new flags)

**Step 1: Update `usage()` to document all new flags**

Ensure the usage heredoc includes:

```
Options:
  --model <model>       Claude model to use (default: opus)
  --fallback-model <m>  Fallback model on rate limit/timeout (optional)
  --dir <path>          Target directory for task execution (default: current dir)
  --dry-run             Parse and show tasks without executing
  --reset               Clear state file and start fresh
  --status              Show progress of current task file
  --help                Show this help message
  --version             Show version
```

**Step 2: Bump VERSION**

Change `VERSION="0.1.0"` to `VERSION="0.2.0"`.

**Step 3: Update CLAUDE.md**

Add `--fallback-model` to the commands section and mention the boot file.

**Step 4: Run all tests**

```bash
bash tests/test-dir-flag.sh && bash tests/test-features.sh
```

Expected: All PASS.

**Step 5: Commit**

```bash
git add agent-loop.sh tests/test-features.sh CLAUDE.md
git commit -m "chore: bump to v0.2.0, update docs for new features

Add --fallback-model to usage and CLAUDE.md. Document boot file
support. Bump version to 0.2.0."
```
