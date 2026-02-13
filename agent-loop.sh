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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help) usage; exit 0 ;;
            --version) echo "agent-loop $VERSION"; exit 0 ;;
            --model) MODEL="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            --reset) RESET=true; shift ;;
            --status) STATUS=true; shift ;;
            *) TASK_FILE="$1"; shift ;;
        esac
    done
}

main() {
    parse_args "$@"
}

main "$@"
