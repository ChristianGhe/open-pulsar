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

reset_state() {
    echo "Resetting state..."
    rm -rf "$STATE_DIR"
    echo "State cleared."
}

show_status() {
    echo "Status: not yet implemented"
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
    echo "Task file: $TASK_FILE"
    echo "Model: $MODEL"
    echo "Dry run: $DRY_RUN"
}

main "$@"
