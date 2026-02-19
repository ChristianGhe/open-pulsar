# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

agent-loop is a Bash script (`agent-loop.sh`, ~660 lines) that orchestrates multi-step task execution through the Claude Code CLI. It reads task definitions from markdown files and executes them sequentially, with session management, Jujutsu VCS isolation per task, state persistence for resumable runs, and AI-driven retry logic.

## Commands

```bash
# Run tests (end-to-end, bash-based, no framework)
bash tests/test-dir-flag.sh

# Dry-run to verify task parsing without execution
./agent-loop.sh --dry-run tests/sample-tasks.md

# Run with a specific model
./agent-loop.sh --model sonnet tests/minimal-tasks.md

# Check status of a run
./agent-loop.sh --status

# Reset state and start fresh
./agent-loop.sh --reset
```

There is no build step, linter, or formatter — this is a single Bash script.

## Architecture

Everything lives in `agent-loop.sh`. The script is organized into these sections:

1. **Global variables & system prompt** (top) — version, model, color codes, the prompt given to Claude
2. **`parse_tasks`** — reads markdown task files; `## Heading` creates groups, `- text` creates tasks
3. **State management** (`init_state`, `update_task_state`, `get_task_status`) — JSON state in `.agent-loop/state.json` via jq; tracks status, session IDs, jj change IDs, attempts; validates file hash to detect task file edits between runs
4. **Jujutsu integration** (`ensure_jj`, `jj_new_change`, `jj_abandon_change`) — auto-initializes jj, creates per-task changes, abandons on failure; degrades gracefully if jj is absent
5. **`run_claude`** — invokes `claude -p` with `--output-format json`; first task in a group gets a fresh session, subsequent tasks use `--resume <session_id>`
6. **`analyze_failure`** — on failure, calls Claude Haiku to decide whether to retry and extract a hint for the next attempt
7. **`execute_tasks`** — main loop: iterates tasks, manages jj changes, handles retries (max 5), updates state, breaks session chain on failure
8. **`parse_args`** — CLI argument parsing
9. **`main`** — entry point: parse args → parse tasks → init state → execute

### Key design patterns

- **Session continuity within groups**: tasks in the same `## Group` share a Claude session via `--resume`; a new group or a failed task starts a fresh session
- **Per-task VCS isolation**: each task gets its own jj change; failed tasks' changes are abandoned (rolled back)
- **Resumable execution**: state file tracks progress; re-running the same command skips completed/failed tasks
- **AI-driven retry**: Haiku analyzes errors and injects hints into retry prompts rather than retrying blindly

### Runtime directory structure

`.agent-loop/` is created in the target directory (the working directory, or `--dir <path>`):
- `state.json` — execution state
- `logs/NNN-group-slug--task-slug.log` — full Claude JSON output per task

## Dependencies

- bash 4+, jq, claude CLI (required)
- jj / Jujutsu (recommended, optional — graceful degradation)
- sha256sum (Linux standard; macOS needs `brew install coreutils`)

## Testing

Tests are bash scripts in `tests/` using simple pass/fail assertions (`assert_ok`, `assert_fail`). They test CLI flags, argument validation, dry-run parsing, and state management — not live Claude execution.
