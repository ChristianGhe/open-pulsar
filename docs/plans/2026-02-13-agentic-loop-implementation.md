# Agentic Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Bash script that reads tasks from a markdown file and executes them autonomously via Claude Code CLI, with Jujutsu VCS for per-task revertability and AI-driven retry on failure.

**Architecture:** A single `agent-loop.sh` Bash script with helper functions for parsing, state management, jj integration, and Claude invocation. State is persisted in `.agent-loop/state.json`. Each task creates a jj change, runs Claude in print mode, and logs output. Tasks within markdown heading groups share a Claude session.

**Tech Stack:** Bash, Claude Code CLI (`claude -p`), Jujutsu (`jj`), `jq` for JSON parsing, `sha256sum` for file hashing.

---

### Task 1: Project Scaffolding

**Files:**
- Create: `agent-loop.sh`
- Create: `.gitignore`

**Step 1: Create the .gitignore**

```gitignore
.agent-loop/
```

**Step 2: Create the script skeleton with shebang, strict mode, and usage**

Create `agent-loop.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=".agent-loop"
STATE_FILE="$STATE_DIR/state.json"
LOG_DIR="$STATE_DIR/logs"
MODEL="opus"
DRY_RUN=false
MAX_ATTEMPTS=5

SYSTEM_PROMPT='You are an autonomous agent executing tasks from a task list.
Use ALL tools available to you to complete the task thoroughly.
Work in the current directory. Do not ask questions — make reasonable decisions and proceed.
If a task is ambiguous, interpret it in the most useful way and execute.
Commit nothing to git/jj — the outer loop handles version control.'

usage() {
    cat <<'USAGE'
Usage: agent-loop.sh [options] <tasks.md>

Execute tasks from a markdown file using Claude Code CLI.

Options:
  --model <model>   Claude model to use (default: opus)
  --dry-run         Parse and show tasks without executing
  --reset           Clear state file and start fresh
  --status          Show progress of current task file
  --help            Show this help message
  --version         Show version
USAGE
}

main() {
    parse_args "$@"
}

main "$@"
```

**Step 3: Make it executable**

Run: `chmod +x agent-loop.sh`

**Step 4: Verify it runs**

Run: `./agent-loop.sh --help`
Expected: Usage text printed to stdout.

**Step 5: Commit**

```bash
git add agent-loop.sh .gitignore
git commit -m "feat: scaffold agent-loop.sh with usage and strict mode"
```

---

### Task 2: Argument Parsing

**Files:**
- Modify: `agent-loop.sh`

**Step 1: Add the parse_args function**

Add before the `main` function in `agent-loop.sh`:

```bash
parse_args() {
    local task_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model)
                MODEL="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --reset)
                reset_state
                exit 0
                ;;
            --status)
                show_status
                exit 0
                ;;
            --help)
                usage
                exit 0
                ;;
            --version)
                echo "agent-loop $VERSION"
                exit 0
                ;;
            -*)
                echo "Error: Unknown option $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                if [[ -n "$task_file" ]]; then
                    echo "Error: Multiple task files specified" >&2
                    exit 1
                fi
                task_file="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$task_file" ]]; then
        echo "Error: No task file specified" >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$task_file" ]]; then
        echo "Error: Task file not found: $task_file" >&2
        exit 1
    fi

    TASK_FILE="$task_file"
}
```

Add stub functions for `reset_state` and `show_status` (they'll be implemented later):

```bash
reset_state() {
    echo "Resetting state..."
    rm -rf "$STATE_DIR"
    echo "State cleared."
}

show_status() {
    echo "Status: not yet implemented"
}
```

**Step 2: Update main to call the loop after parsing**

```bash
main() {
    parse_args "$@"
    echo "Task file: $TASK_FILE"
    echo "Model: $MODEL"
    echo "Dry run: $DRY_RUN"
}
```

**Step 3: Test argument parsing**

Run: `./agent-loop.sh --model sonnet --dry-run tasks-test.md 2>&1 || true`
Expected: Error about missing file (tasks-test.md doesn't exist yet), confirming parsing got that far.

Run: `echo "## Test" > /tmp/test-tasks.md && ./agent-loop.sh --model sonnet --dry-run /tmp/test-tasks.md`
Expected: Output showing task file, model=sonnet, dry_run=true.

**Step 4: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: add argument parsing with --model, --dry-run, --reset, --status"
```

---

### Task 3: Markdown Task File Parser

**Files:**
- Modify: `agent-loop.sh`

**Step 1: Create a test task file for development**

Create `tests/sample-tasks.md`:

```markdown
## Backend API
- Create a REST API with endpoints for users CRUD
- Add authentication middleware using JWT
- Write integration tests for all endpoints

## Frontend
- Build a React dashboard showing user list
- Add login form connected to the auth API

## Documentation
- Write API docs in OpenAPI format
```

**Step 2: Add the parse_tasks function**

This function reads the markdown and outputs structured data. Add to `agent-loop.sh` before `main`:

```bash
# Globals populated by parse_tasks
declare -a TASK_GROUPS=()     # group name for each task
declare -a TASK_TEXTS=()      # task text for each task
TOTAL_TASKS=0

parse_tasks() {
    local file="$1"
    local current_group="ungrouped"
    local in_multiline=false
    local current_task=""

    TASK_GROUPS=()
    TASK_TEXTS=()
    TOTAL_TASKS=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Group heading
        if [[ "$line" =~ ^##[[:space:]]+(.+)$ ]]; then
            # Flush any pending multiline task
            if [[ -n "$current_task" ]]; then
                TASK_GROUPS+=("$current_group")
                TASK_TEXTS+=("$current_task")
                ((TOTAL_TASKS++))
                current_task=""
            fi
            current_group="${BASH_REMATCH[1]}"
            in_multiline=false
            continue
        fi

        # Task line (starts with -)
        if [[ "$line" =~ ^-[[:space:]]+(.+)$ ]]; then
            # Flush previous task if any
            if [[ -n "$current_task" ]]; then
                TASK_GROUPS+=("$current_group")
                TASK_TEXTS+=("$current_task")
                ((TOTAL_TASKS++))
            fi
            current_task="${BASH_REMATCH[1]}"
            in_multiline=true
            continue
        fi

        # Continuation line (indented, part of multiline task)
        if $in_multiline && [[ "$line" =~ ^[[:space:]]+(.+)$ ]]; then
            current_task+=" ${BASH_REMATCH[1]}"
            continue
        fi

        # Blank or other line ends multiline
        if $in_multiline && [[ -n "$current_task" ]]; then
            TASK_GROUPS+=("$current_group")
            TASK_TEXTS+=("$current_task")
            ((TOTAL_TASKS++))
            current_task=""
            in_multiline=false
        fi
    done < "$file"

    # Flush final task
    if [[ -n "$current_task" ]]; then
        TASK_GROUPS+=("$current_group")
        TASK_TEXTS+=("$current_task")
        ((TOTAL_TASKS++))
    fi
}
```

**Step 3: Add a dry-run display function**

```bash
show_parsed_tasks() {
    local current_group=""
    for i in $(seq 0 $((TOTAL_TASKS - 1))); do
        if [[ "${TASK_GROUPS[$i]}" != "$current_group" ]]; then
            current_group="${TASK_GROUPS[$i]}"
            echo ""
            echo "## $current_group"
        fi
        echo "  [$((i + 1))/$TOTAL_TASKS] ${TASK_TEXTS[$i]}"
    done
    echo ""
    echo "Total: $TOTAL_TASKS tasks"
}
```

**Step 4: Wire parsing into main**

```bash
main() {
    parse_args "$@"
    parse_tasks "$TASK_FILE"

    if $DRY_RUN; then
        show_parsed_tasks
        exit 0
    fi

    echo "Parsed $TOTAL_TASKS tasks from $TASK_FILE"
}
```

**Step 5: Test the parser**

Run: `./agent-loop.sh --dry-run tests/sample-tasks.md`
Expected output:
```
## Backend API
  [1/7] Create a REST API with endpoints for users CRUD
  [2/7] Add authentication middleware using JWT
  [3/7] Write integration tests for all endpoints

## Frontend
  [4/7] Build a React dashboard showing user list
  [5/7] Add login form connected to the auth API

## Documentation
  [6/7] Write API docs in OpenAPI format

Total: 7 tasks
```

Note: The sample has 6 tasks not 7 — verify the count matches the actual file.

**Step 6: Commit**

```bash
git add agent-loop.sh tests/sample-tasks.md
git commit -m "feat: add markdown task file parser with dry-run display"
```

---

### Task 4: State Management

**Files:**
- Modify: `agent-loop.sh`

**Step 1: Add dependency check for jq**

Add near the top of the script, after variable declarations:

```bash
check_dependencies() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed." >&2
        echo "Install with: sudo apt install jq" >&2
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo "Error: claude CLI is required but not installed." >&2
        exit 1
    fi
}
```

**Step 2: Add state initialization function**

```bash
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

init_state() {
    mkdir -p "$LOG_DIR"

    local file_hash
    file_hash=$(sha256sum "$TASK_FILE" | cut -d' ' -f1)

    if [[ -f "$STATE_FILE" ]]; then
        local stored_hash
        stored_hash=$(jq -r '.task_file_hash' "$STATE_FILE")
        if [[ "$stored_hash" != "$file_hash" ]]; then
            echo "Error: Task file has changed since last run." >&2
            echo "Run with --reset to clear state and start fresh." >&2
            exit 1
        fi
        return
    fi

    # Build initial state
    local tasks_json="[]"
    for i in $(seq 0 $((TOTAL_TASKS - 1))); do
        local group="${TASK_GROUPS[$i]}"
        local task="${TASK_TEXTS[$i]}"
        local group_slug
        group_slug=$(slugify "$group")
        local task_slug
        task_slug=$(slugify "$task" | cut -c1-50)
        local log_name
        log_name=$(printf "%03d-%s--%s.log" "$((i + 1))" "$group_slug" "$task_slug")

        tasks_json=$(echo "$tasks_json" | jq \
            --arg group "$group" \
            --arg task "$task" \
            --arg log "$log_name" \
            --argjson index "$((i + 1))" \
            '. += [{
                index: $index,
                group: $group,
                task: $task,
                status: "pending",
                session_id: null,
                jj_change: null,
                log: $log,
                attempts: 0
            }]')
    done

    jq -n \
        --arg task_file "$TASK_FILE" \
        --arg hash "$file_hash" \
        --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson tasks "$tasks_json" \
        '{
            task_file: $task_file,
            task_file_hash: $hash,
            started_at: $started,
            tasks: $tasks
        }' > "$STATE_FILE"
}
```

**Step 3: Add state update function**

```bash
update_task_state() {
    local task_index="$1"  # 0-based
    local field="$2"
    local value="$3"

    local tmp
    tmp=$(mktemp)
    jq --argjson idx "$task_index" --arg field "$field" --arg val "$value" \
        '.tasks[$idx][$field] = $val' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}

update_task_state_raw() {
    # For non-string values (numbers, null)
    local task_index="$1"
    local field="$2"
    local value="$3"

    local tmp
    tmp=$(mktemp)
    jq --argjson idx "$task_index" --arg field "$field" --argjson val "$value" \
        '.tasks[$idx][$field] = $val' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}

get_task_status() {
    local task_index="$1"  # 0-based
    jq -r --argjson idx "$task_index" '.tasks[$idx].status' "$STATE_FILE"
}

get_task_field() {
    local task_index="$1"  # 0-based
    local field="$2"
    jq -r --argjson idx "$task_index" --arg field "$field" '.tasks[$idx][$field]' "$STATE_FILE"
}
```

**Step 4: Implement show_status properly**

Replace the stub:

```bash
show_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No active run found."
        exit 0
    fi

    local task_file total completed failed pending
    task_file=$(jq -r '.task_file' "$STATE_FILE")
    total=$(jq '.tasks | length' "$STATE_FILE")
    completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$STATE_FILE")
    failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$STATE_FILE")
    pending=$((total - completed - failed))

    echo "Task file: $task_file"
    echo "Progress: $completed/$total completed, $failed failed, $pending pending"
    echo ""

    jq -r '.tasks[] | "  [\(.status | if . == "completed" then "OK" elif . == "failed" then "FAIL" else "..." end)] \(.group) > \(.task)"' "$STATE_FILE"
}
```

**Step 5: Wire into main**

Update `main` to call `check_dependencies` and `init_state`:

```bash
main() {
    parse_args "$@"
    check_dependencies
    parse_tasks "$TASK_FILE"

    if $DRY_RUN; then
        show_parsed_tasks
        exit 0
    fi

    init_state
    echo "Parsed $TOTAL_TASKS tasks from $TASK_FILE"
}
```

**Step 6: Test state initialization**

Run: `./agent-loop.sh tests/sample-tasks.md`
Run: `cat .agent-loop/state.json | jq .`
Expected: JSON with all tasks in "pending" status, correct file hash.

Run: `./agent-loop.sh --status`
Expected: Status display showing all tasks as pending.

**Step 7: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: add state management with JSON persistence and status display"
```

---

### Task 5: Jujutsu Integration

**Files:**
- Modify: `agent-loop.sh`

**Step 1: Add jj initialization function**

```bash
ensure_jj() {
    if command -v jj &>/dev/null; then
        if ! jj root &>/dev/null 2>&1; then
            echo "Initializing Jujutsu..."
            if [[ -d ".git" ]]; then
                jj git init --colocate 2>&1
            else
                jj init 2>&1
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

**Step 2: Add jj change creation function**

```bash
jj_new_change() {
    local message="$1"
    if ! $JJ_AVAILABLE; then
        echo ""
        return
    fi

    local output
    output=$(jj new -m "$message" 2>&1)
    # Extract the change ID from jj output
    local change_id
    change_id=$(jj log -r @ --no-graph -T 'change_id.short()' 2>/dev/null || echo "unknown")
    echo "$change_id"
}

jj_abandon_change() {
    local change_id="$1"
    if $JJ_AVAILABLE && [[ -n "$change_id" && "$change_id" != "null" ]]; then
        jj abandon "$change_id" 2>/dev/null || true
    fi
}
```

**Step 3: Wire into main**

Add `ensure_jj` call in main, after `init_state`:

```bash
main() {
    parse_args "$@"
    check_dependencies
    parse_tasks "$TASK_FILE"

    if $DRY_RUN; then
        show_parsed_tasks
        exit 0
    fi

    init_state
    ensure_jj
    echo "Ready to execute $TOTAL_TASKS tasks from $TASK_FILE"
}
```

**Step 4: Test jj integration**

Run: `./agent-loop.sh tests/sample-tasks.md`
Expected: Either "Jujutsu initialized." or the warning about jj not being installed.

**Step 5: Commit**

```bash
git add agent-loop.sh
git commit -m "feat: add Jujutsu VCS integration with auto-init"
```

---

### Task 6: Core Execution Loop

**Files:**
- Modify: `agent-loop.sh`

**Step 1: Add the Claude invocation function**

```bash
run_claude() {
    local task_text="$1"
    local session_id="$2"  # empty string for new session
    local log_file="$3"
    local hint="$4"        # optional hint from retry analysis

    local prompt="$task_text"
    if [[ -n "$hint" ]]; then
        prompt="$task_text

IMPORTANT HINT FROM PREVIOUS ATTEMPT: $hint"
    fi

    local claude_args=(
        -p
        --dangerously-skip-permissions
        --model "$MODEL"
        --output-format json
    )

    if [[ -n "$session_id" ]]; then
        claude_args+=(--resume "$session_id")
    else
        claude_args+=(--system-prompt "$SYSTEM_PROMPT")
    fi

    # Run claude, capture output
    local output
    local exit_code=0
    output=$(CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>&1) || exit_code=$?

    # Save raw output to log
    echo "$output" > "$LOG_DIR/$log_file"

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        return 1
    fi

    # Extract session_id from JSON output
    local new_session_id
    new_session_id=$(echo "$output" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    echo "$new_session_id"
    return 0
}
```

**Step 2: Add the AI retry analysis function**

```bash
analyze_failure() {
    local task_text="$1"
    local log_file="$2"

    local error_output
    error_output=$(tail -c 2000 "$LOG_DIR/$log_file" 2>/dev/null || echo "No output captured")

    local analysis_prompt="A task failed during autonomous execution. Analyze the error and decide if retrying would help.

TASK: $task_text

ERROR OUTPUT (last 2000 chars):
$error_output

Respond with ONLY valid JSON, no other text:
{\"retry\": true or false, \"reason\": \"brief explanation\", \"hint\": \"specific suggestion for next attempt or empty string\"}"

    local result
    result=$(CLAUDECODE= claude -p \
        --model haiku \
        --dangerously-skip-permissions \
        --output-format json \
        "$analysis_prompt" 2>/dev/null) || true

    # Extract the result text and parse the inner JSON
    local inner
    inner=$(echo "$result" | jq -r '.result // empty' 2>/dev/null || echo "")

    if [[ -z "$inner" ]]; then
        echo '{"retry": false, "reason": "Could not analyze failure", "hint": ""}'
        return
    fi

    # Try to parse the inner JSON; fall back to no-retry
    if echo "$inner" | jq . &>/dev/null 2>&1; then
        echo "$inner"
    else
        echo '{"retry": false, "reason": "Could not parse analysis", "hint": ""}'
    fi
}
```

**Step 3: Add the main execution loop**

```bash
execute_tasks() {
    local current_group=""
    local session_id=""
    local interrupted=false

    trap 'interrupted=true; echo ""; echo "Interrupted. Progress saved."; exit 130' INT TERM

    for i in $(seq 0 $((TOTAL_TASKS - 1))); do
        if $interrupted; then
            break
        fi

        local group="${TASK_GROUPS[$i]}"
        local task="${TASK_TEXTS[$i]}"
        local status
        status=$(get_task_status "$i")

        # Skip completed/failed tasks
        if [[ "$status" == "completed" || "$status" == "failed" ]]; then
            continue
        fi

        # New group = new session
        if [[ "$group" != "$current_group" ]]; then
            current_group="$group"
            session_id=""
        fi

        local log_name
        log_name=$(get_task_field "$i" "log")

        echo ""
        echo "[$((i + 1))/$TOTAL_TASKS] $group > $task"

        # Create jj change
        local jj_change=""
        jj_change=$(jj_new_change "agent-loop: $group / $task")
        if [[ -n "$jj_change" ]]; then
            echo "  jj: created change $jj_change"
            update_task_state "$i" "jj_change" "$jj_change"
        fi

        update_task_state "$i" "status" "running"

        # Attempt loop
        local attempt=0
        local success=false
        local hint=""

        while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
            ((attempt++))

            if [[ $attempt -gt 1 ]]; then
                echo "  retry: attempt $attempt/$MAX_ATTEMPTS"
                # Abandon previous jj change and create new one
                jj_abandon_change "$jj_change"
                jj_change=$(jj_new_change "agent-loop: $group / $task (attempt $attempt)")
                if [[ -n "$jj_change" ]]; then
                    update_task_state "$i" "jj_change" "$jj_change"
                fi
                # Use fresh session for retries
                session_id=""
            fi

            echo "  claude: running... (output -> $LOG_DIR/$log_name)"

            local new_session_id
            new_session_id=$(run_claude "$task" "$session_id" "$log_name" "$hint")
            local run_exit=$?

            if [[ $run_exit -eq 0 && -n "$new_session_id" ]]; then
                session_id="$new_session_id"
                update_task_state "$i" "status" "completed"
                update_task_state "$i" "session_id" "$session_id"
                update_task_state_raw "$i" "attempts" "$attempt"
                echo "  completed (session $session_id)"
                success=true
                break
            fi

            echo "  failed on attempt $attempt"

            # AI-driven retry analysis
            if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
                echo "  analyzing failure..."
                local analysis
                analysis=$(analyze_failure "$task" "$log_name")
                local should_retry
                should_retry=$(echo "$analysis" | jq -r '.retry' 2>/dev/null || echo "false")
                local reason
                reason=$(echo "$analysis" | jq -r '.reason' 2>/dev/null || echo "")
                hint=$(echo "$analysis" | jq -r '.hint' 2>/dev/null || echo "")

                echo "  analysis: $reason"

                if [[ "$should_retry" != "true" ]]; then
                    echo "  AI decided not to retry. Moving on."
                    break
                fi

                echo "  AI suggests retry with hint: $hint"
            fi
        done

        if ! $success; then
            update_task_state "$i" "status" "failed"
            update_task_state_raw "$i" "attempts" "$attempt"
            jj_abandon_change "$jj_change"
            echo "  FAILED after $attempt attempt(s). jj change abandoned."
            # Break session chain
            session_id=""
        fi
    done
}
```

**Step 4: Add summary function**

```bash
show_summary() {
    echo ""
    echo "========================================="
    echo "  Execution Summary"
    echo "========================================="

    local completed failed pending
    completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$STATE_FILE")
    failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$STATE_FILE")
    pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$STATE_FILE")

    echo "  Completed: $completed"
    echo "  Failed:    $failed"
    echo "  Pending:   $pending"
    echo "  Total:     $TOTAL_TASKS"
    echo ""

    if [[ "$failed" -gt 0 ]]; then
        echo "  Failed tasks:"
        jq -r '.tasks[] | select(.status == "failed") | "    - \(.group) > \(.task)"' "$STATE_FILE"
        echo ""
    fi

    echo "  Logs: $LOG_DIR/"
    echo "  State: $STATE_FILE"
    echo "========================================="
}
```

**Step 5: Wire into main**

Replace the echo in `main` with the actual execution:

```bash
main() {
    parse_args "$@"
    check_dependencies
    parse_tasks "$TASK_FILE"

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

**Step 6: Test with a minimal task file**

Create `tests/minimal-tasks.md`:
```markdown
## Test
- Say hello world
```

Run: `./agent-loop.sh tests/minimal-tasks.md`
Expected: The script creates a jj change (or warns about jj), runs Claude on "Say hello world", saves the log, marks it completed, and shows a summary.

**Step 7: Commit**

```bash
git add agent-loop.sh tests/minimal-tasks.md
git commit -m "feat: add core execution loop with Claude invocation and AI-driven retry"
```

---

### Task 7: End-to-End Testing

**Files:**
- Modify: `tests/sample-tasks.md` (already exists)

**Step 1: Run dry-run to verify parsing**

Run: `./agent-loop.sh --dry-run tests/sample-tasks.md`
Expected: All tasks listed with correct grouping and numbering.

**Step 2: Run a real execution with minimal tasks**

Create `tests/two-group-test.md`:

```markdown
## Group A
- List the files in the current directory and describe them briefly
- Create a file called hello.txt with the text "Hello from agent-loop"

## Group B
- Read hello.txt and tell me what it says
```

Run: `./agent-loop.sh tests/two-group-test.md`
Expected:
- Group A tasks share a session (second task resumes first)
- Group B gets a fresh session
- `hello.txt` is created
- All marked completed
- Logs exist in `.agent-loop/logs/`

**Step 3: Test resume capability**

Run: `./agent-loop.sh tests/two-group-test.md`
Expected: All tasks skipped (already completed). Summary shows 3/3 completed.

**Step 4: Test --reset**

Run: `./agent-loop.sh --reset`
Run: `./agent-loop.sh --status`
Expected: "No active run found."

**Step 5: Test --status during/after run**

Run: `./agent-loop.sh tests/two-group-test.md` then in another terminal: `./agent-loop.sh --status`
Expected: Shows progress with completed/pending counts.

**Step 6: Clean up test artifacts**

Run: `rm -f hello.txt && rm -rf .agent-loop`

**Step 7: Commit any fixes**

```bash
git add -A
git commit -m "test: add end-to-end test task files and fix issues found during testing"
```

---

### Task 8: Polish and Documentation

**Files:**
- Modify: `agent-loop.sh` (minor polish)
- Create: `tests/two-group-test.md` (if not already committed)

**Step 1: Add color output support**

Add near the top of `agent-loop.sh`:

```bash
# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi
```

Update echo statements to use colors:
- Task headers: `BOLD` + `BLUE`
- Success: `GREEN`
- Failure: `RED`
- Warnings: `YELLOW`

**Step 2: Add a header banner**

```bash
show_banner() {
    echo -e "${BOLD}agent-loop $VERSION${NC}"
    echo ""
}
```

Call at the start of `main`, before `parse_args`.

**Step 3: Test the polished output**

Run: `./agent-loop.sh --dry-run tests/sample-tasks.md`
Expected: Colored, formatted output.

**Step 4: Commit**

```bash
git add agent-loop.sh tests/
git commit -m "feat: add colored output and polish console formatting"
```

---

## Summary of Files

| File | Action | Purpose |
|------|--------|---------|
| `agent-loop.sh` | Create | Main script — parsing, state, jj, Claude invocation, retry |
| `.gitignore` | Create | Ignore `.agent-loop/` runtime directory |
| `tests/sample-tasks.md` | Create | Sample task file for development/testing |
| `tests/minimal-tasks.md` | Create | Minimal single-task test file |
| `tests/two-group-test.md` | Create | Multi-group test file for session management |

## Execution Order

Tasks must be executed in order (1 through 8). Each builds on the previous.

## Dependencies

- `bash` 4+ (for associative arrays and `BASH_REMATCH`)
- `jq` (JSON parsing)
- `claude` CLI (Claude Code)
- `jj` (Jujutsu VCS — optional, graceful degradation)
- `sha256sum` (file hashing — standard on Linux)
