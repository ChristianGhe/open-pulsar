#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR=""
MODEL="opus"
DRY_RUN=false
DO_RESET=false
DO_STATUS=false
MAX_ATTEMPTS=5

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

SYSTEM_PROMPT='You are an autonomous agent executing tasks from a task list.
Use ALL tools available to you to complete the task thoroughly.
Work in the current directory. Do not ask questions — make reasonable decisions and proceed.
If a task is ambiguous, interpret it in the most useful way and execute.
Commit nothing to git/jj — the outer loop handles version control.'

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

show_banner() {
    echo -e "${BOLD}agent-loop $VERSION${NC}"
    if [[ -n "$TARGET_DIR" && "$TARGET_DIR" != "$(pwd)" ]]; then
        echo -e "  ${BLUE}target:${NC} $TARGET_DIR"
    fi
    echo ""
}

usage() {
    cat <<'USAGE'
Usage: agent-loop.sh [options] <tasks.md>

Execute tasks from a markdown file using Claude Code CLI.

Options:
  --model <model>   Claude model to use (default: opus)
  --dir <path>      Target directory for task execution (default: current dir)
  --dry-run         Parse and show tasks without executing
  --reset           Clear state file and start fresh
  --status          Show progress of current task file
  --help            Show this help message
  --version         Show version
USAGE
}

reset_state() {
    echo "Resetting state..."
    rm -rf "$STATE_DIR"
    echo "State cleared."
}

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
                ((TOTAL_TASKS++)) || true
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
                ((TOTAL_TASKS++)) || true
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
            ((TOTAL_TASKS++)) || true
            current_task=""
            in_multiline=false
        fi
    done < "$file"

    # Flush final task
    if [[ -n "$current_task" ]]; then
        TASK_GROUPS+=("$current_group")
        TASK_TEXTS+=("$current_task")
        ((TOTAL_TASKS++)) || true
    fi
}

show_parsed_tasks() {
    local current_group=""
    for i in $(seq 0 $((TOTAL_TASKS - 1))); do
        if [[ "${TASK_GROUPS[$i]}" != "$current_group" ]]; then
            current_group="${TASK_GROUPS[$i]}"
            echo ""
            echo -e "  ${BOLD}${BLUE}## $current_group${NC}"
        fi
        echo "  [$((i + 1))/$TOTAL_TASKS] ${TASK_TEXTS[$i]}"
    done
    echo ""
    echo "Total: $TOTAL_TASKS tasks"
}

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

jj_abandon_change() {
    local change_id="$1"
    if $JJ_AVAILABLE && [[ -n "$change_id" && "$change_id" != "null" ]]; then
        (cd "$TARGET_DIR" && jj abandon "$change_id" 2>/dev/null) || true
    fi
}

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
    output=$(cd "$TARGET_DIR" && CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>&1) || exit_code=$?

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
        echo -e "${BOLD}${BLUE}[$((i + 1))/$TOTAL_TASKS] $group > $task${NC}"

        # Create jj change
        local jj_change=""
        jj_change=$(jj_new_change "agent-loop: $group / $task")
        if [[ -n "$jj_change" ]]; then
            echo -e "  ${YELLOW}jj:${NC} created change $jj_change"
            update_task_state "$i" "jj_change" "$jj_change"
        fi

        update_task_state "$i" "status" "running"

        # Attempt loop
        local attempt=0
        local success=false
        local hint=""

        while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
            ((attempt++)) || true

            if [[ $attempt -gt 1 ]]; then
                echo -e "  ${YELLOW}retry:${NC} attempt $attempt/$MAX_ATTEMPTS"
                # Abandon previous jj change and create new one
                jj_abandon_change "$jj_change"
                jj_change=$(jj_new_change "agent-loop: $group / $task (attempt $attempt)")
                if [[ -n "$jj_change" ]]; then
                    update_task_state "$i" "jj_change" "$jj_change"
                fi
                # Use fresh session for retries
                session_id=""
            fi

            echo -e "  ${BLUE}claude:${NC} running... (output -> $LOG_DIR/$log_name)"

            local new_session_id
            new_session_id=$(run_claude "$task" "$session_id" "$log_name" "$hint")
            local run_exit=$?

            if [[ $run_exit -eq 0 && -n "$new_session_id" ]]; then
                session_id="$new_session_id"
                update_task_state "$i" "status" "completed"
                update_task_state "$i" "session_id" "$session_id"
                update_task_state_raw "$i" "attempts" "$attempt"
                echo -e "  ${GREEN}completed${NC} (session $session_id)"
                success=true
                break
            fi

            echo -e "  ${RED}failed${NC} on attempt $attempt"

            # AI-driven retry analysis
            if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
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

                echo "  AI suggests retry with hint: $hint"
            fi
        done

        if ! $success; then
            update_task_state "$i" "status" "failed"
            update_task_state_raw "$i" "attempts" "$attempt"
            jj_abandon_change "$jj_change"
            echo -e "  ${RED}FAILED after $attempt attempt(s). jj change abandoned.${NC}"
            # Break session chain
            session_id=""
        fi
    done
}

show_summary() {
    echo ""
    echo "========================================="
    echo -e "${BOLD}  Execution Summary${NC}"
    echo "========================================="

    local completed failed pending
    completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$STATE_FILE")
    failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$STATE_FILE")
    pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$STATE_FILE")

    echo -e "  Completed: ${GREEN}$completed${NC}"
    if [[ "$failed" -gt 0 ]]; then
        echo -e "  Failed:    ${RED}$failed${NC}"
    else
        echo "  Failed:    $failed"
    fi
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
    if [[ "$TARGET_DIR" != "$(pwd)" ]]; then
        echo "  Target: $TARGET_DIR"
    fi
    echo "========================================="
}

parse_args() {
    local task_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model)
                MODEL="$2"
                shift 2
                ;;
            --dir)
                if [[ -z "${2:-}" || ! -d "$2" ]]; then
                    echo "Error: --dir requires a valid directory path" >&2
                    exit 1
                fi
                TARGET_DIR="$(cd "$2" && pwd)"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --reset)
                DO_RESET=true
                shift
                ;;
            --status)
                DO_STATUS=true
                shift
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

    if $DO_RESET || $DO_STATUS; then
        return
    fi

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

main() {
    parse_args "$@"

    # Derive paths from TARGET_DIR
    TARGET_DIR="${TARGET_DIR:-$(pwd)}"
    STATE_DIR="$TARGET_DIR/.agent-loop"
    STATE_FILE="$STATE_DIR/state.json"
    LOG_DIR="$STATE_DIR/logs"

    show_banner

    if $DO_RESET; then
        reset_state
        exit 0
    fi

    if $DO_STATUS; then
        show_status
        exit 0
    fi

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

main "$@"
