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
            echo "## $current_group"
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

main "$@"
