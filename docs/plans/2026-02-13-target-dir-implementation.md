# --dir Flag Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `--dir <path>` flag so agent-loop.sh can target any project folder for task execution.

**Architecture:** Add a `TARGET_DIR` variable defaulting to `$(pwd)`. Derive all paths (state, logs) from it. Run jj and claude in subshells that `cd` into the target. Defer `--reset`/`--status` so `--dir` is parsed first.

**Tech Stack:** Bash, jq, Claude CLI, Jujutsu

---

### Task 1: Add TARGET_DIR global and --dir flag to argument parser

**Files:**
- Modify: `agent-loop.sh:6` (add global)
- Modify: `agent-loop.sh:48-62` (update usage)
- Modify: `agent-loop.sh:545-602` (update parse_args)

**Step 1: Add the global variable**

At line 6, after `SCRIPT_DIR=...`, add:

```bash
TARGET_DIR=""
```

**Step 2: Add --dir to usage text**

In the `usage()` function, add a new line after `--model`:

```
  --dir <path>    Target directory for task execution (default: current dir)
```

**Step 3: Add --dir case to parse_args**

In the `case` block inside `parse_args()`, add before the `--dry-run` case:

```bash
            --dir)
                if [[ -z "${2:-}" || ! -d "$2" ]]; then
                    echo "Error: --dir requires a valid directory path" >&2
                    exit 1
                fi
                TARGET_DIR="$(cd "$2" && pwd)"
                shift 2
                ;;
```

**Step 4: Verify it parses correctly**

Run: `./agent-loop.sh --help`
Expected: Output includes `--dir <path>` in options list.

Run: `./agent-loop.sh --dir /nonexistent tests/minimal-tasks.md`
Expected: Error message about invalid directory.

Run: `./agent-loop.sh --dir /tmp --dry-run tests/minimal-tasks.md`
Expected: Parses tasks successfully (dry-run output).

**Step 5: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: add --dir flag to argument parser"
```

---

### Task 2: Defer --reset and --status to run after path derivation

**Files:**
- Modify: `agent-loop.sh:545-602` (parse_args: defer flags)
- Modify: `agent-loop.sh:604-620` (main: process deferred flags)

**Step 1: Change --reset and --status from immediate exit to flags**

In `parse_args()`, replace the `--reset)` case:

```bash
            --reset)
                DO_RESET=true
                shift
                ;;
```

Replace the `--status)` case:

```bash
            --status)
                DO_STATUS=true
                shift
                ;;
```

Add two globals near the top of the file (next to `DRY_RUN`):

```bash
DO_RESET=false
DO_STATUS=false
```

**Step 2: Process deferred flags in main()**

In `main()`, after `parse_args "$@"` and before `check_dependencies`, add path derivation and deferred flag handling:

```bash
    # Derive paths from TARGET_DIR
    TARGET_DIR="${TARGET_DIR:-$(pwd)}"
    STATE_DIR="$TARGET_DIR/.agent-loop"
    STATE_FILE="$STATE_DIR/state.json"
    LOG_DIR="$STATE_DIR/logs"

    if $DO_RESET; then
        reset_state
        exit 0
    fi

    if $DO_STATUS; then
        show_status
        exit 0
    fi
```

Also remove the early `STATE_DIR`, `STATE_FILE`, `LOG_DIR` assignments from the top of the file (lines 6-8). They'll be set in `main()` now.

**Step 3: Verify deferred flags work**

Run: `./agent-loop.sh --status`
Expected: "No active run found." (same as before — paths default to $(pwd)).

Run: `./agent-loop.sh --dir /tmp --status`
Expected: "No active run found." (checks /tmp/.agent-loop/).

Run: `./agent-loop.sh --dir /tmp --reset`
Expected: "Resetting state..." then "State cleared." (operates on /tmp/.agent-loop/).

**Step 4: Commit**

```bash
git add agent-loop.sh
git commit -m "refactor: defer --reset/--status to run after path derivation"
```

---

### Task 3: Update Jujutsu functions to use TARGET_DIR

**Files:**
- Modify: `agent-loop.sh:270-309` (ensure_jj, jj_new_change, jj_abandon_change)

**Step 1: Update ensure_jj to operate in TARGET_DIR**

Replace `ensure_jj()` with:

```bash
ensure_jj() {
    if command -v jj &>/dev/null; then
        if ! (cd "$TARGET_DIR" && jj root &>/dev/null 2>&1); then
            echo "Initializing Jujutsu in $TARGET_DIR..."
            if [[ -d "$TARGET_DIR/.git" ]]; then
                (cd "$TARGET_DIR" && jj git init --colocate 2>&1)
            else
                (cd "$TARGET_DIR" && jj init 2>&1)
            fi
            echo "Jujutsu initialized."
        fi
        JJ_AVAILABLE=true
    else
        echo "Warning: jj not installed. Running without version control isolation." >&2
        echo "Install jj for per-task revertability: https://jj-vcs.github.io/jj/latest/install-and-setup/" >&2
        JJ_AVAILABLE=false
    fi
}
```

**Step 2: Update jj_new_change to operate in TARGET_DIR**

Replace `jj_new_change()` with:

```bash
jj_new_change() {
    local message="$1"
    if ! $JJ_AVAILABLE; then
        echo ""
        return
    fi

    local output
    output=$(cd "$TARGET_DIR" && jj new -m "$message" 2>&1)
    local change_id
    change_id=$(cd "$TARGET_DIR" && jj log -r @ --no-graph -T 'change_id.short()' 2>/dev/null || echo "unknown")
    echo "$change_id"
}
```

**Step 3: Update jj_abandon_change to operate in TARGET_DIR**

Replace `jj_abandon_change()` with:

```bash
jj_abandon_change() {
    local change_id="$1"
    if $JJ_AVAILABLE && [[ -n "$change_id" && "$change_id" != "null" ]]; then
        (cd "$TARGET_DIR" && jj abandon "$change_id" 2>/dev/null) || true
    fi
}
```

**Step 4: Verify (visual inspection)**

The jj functions now all use `(cd "$TARGET_DIR" && ...)` subshells. Since we can't easily test jj without a real run, verify by reading the code.

**Step 5: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: run Jujutsu operations in TARGET_DIR"
```

---

### Task 4: Update run_claude to execute in TARGET_DIR

**Files:**
- Modify: `agent-loop.sh:311-355` (run_claude function)

**Step 1: Change the claude invocation to cd into TARGET_DIR**

In `run_claude()`, replace line 340:

```bash
    output=$(CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>&1) || exit_code=$?
```

With:

```bash
    output=$(cd "$TARGET_DIR" && CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>&1) || exit_code=$?
```

**Step 2: Verify (visual inspection)**

The only change is prepending `cd "$TARGET_DIR" &&` to the claude invocation. This runs claude with the target as its working directory.

**Step 3: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: run Claude in TARGET_DIR working directory"
```

---

### Task 5: Update UI to show target directory

**Files:**
- Modify: `agent-loop.sh:43-46` (show_banner)
- Modify: `agent-loop.sh:513-543` (show_summary)
- Modify: `agent-loop.sh:604-620` (main execution message)

**Step 1: Update show_banner to show target dir**

Replace `show_banner()` with:

```bash
show_banner() {
    echo -e "${BOLD}agent-loop $VERSION${NC}"
    if [[ -n "$TARGET_DIR" && "$TARGET_DIR" != "$(pwd)" ]]; then
        echo -e "  ${BLUE}target:${NC} $TARGET_DIR"
    fi
    echo ""
}
```

Note: `show_banner` is called in `main()` before `TARGET_DIR` is set. Move the `show_banner` call to after path derivation in `main()`.

**Step 2: Update the execution message in main()**

In `main()`, change:

```bash
    echo "Executing $TOTAL_TASKS tasks from $TASK_FILE (model: $MODEL)"
```

To:

```bash
    echo -e "Executing $TOTAL_TASKS tasks from ${BOLD}$TASK_FILE${NC} (model: $MODEL)"
```

**Step 3: Update show_summary to include target**

In `show_summary()`, after the "State:" line, add:

```bash
    if [[ "$TARGET_DIR" != "$(pwd)" ]]; then
        echo "  Target: $TARGET_DIR"
    fi
```

**Step 4: Verify**

Run: `./agent-loop.sh --dir /tmp --dry-run tests/minimal-tasks.md`
Expected: Banner shows "target: /tmp".

Run: `./agent-loop.sh --dry-run tests/minimal-tasks.md`
Expected: Banner does NOT show target line (default behavior unchanged).

**Step 5: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: show target directory in banner and summary"
```

---

### Task 6: End-to-end verification

**Files:**
- Create: `tests/test-dir-flag.sh` (test script)

**Step 1: Write an end-to-end test script**

Create `tests/test-dir-flag.sh`:

```bash
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
    if echo "$output" | grep -q "$pattern"; then
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
```

**Step 2: Run the test script**

Run: `bash tests/test-dir-flag.sh`
Expected: All tests pass.

**Step 3: Fix any failures**

If any tests fail, fix the issue in `agent-loop.sh` and re-run.

**Step 4: Commit**

```bash
git add tests/test-dir-flag.sh agent-loop.sh
git commit -m "test: add end-to-end tests for --dir flag"
```
