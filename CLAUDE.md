# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

open-pulsar is a Bash script (`agent-loop.sh`, ~820 lines) that orchestrates multi-step task execution through the Claude Code CLI. It reads task definitions from markdown files and executes them sequentially, with session management, Jujutsu VCS isolation per task, state persistence for resumable runs, and AI-driven retry logic.

## Commands

```bash
# Run tests (end-to-end, bash-based, no framework)
bash tests/test-dir-flag.sh

# Dry-run to verify task parsing without execution
./agent-loop.sh --dry-run tests/sample-tasks.md

# Run with a specific model
./agent-loop.sh --model sonnet tests/minimal-tasks.md

# Run with a fallback model for rate-limit/timeout failover
./agent-loop.sh --model opus --fallback-model sonnet tasks.md

# Check status of a run
./agent-loop.sh --status

# Reset state and start fresh
./agent-loop.sh --reset
```

There is no build step, linter, or formatter — this is a single Bash script.

## Architecture

Everything lives in `agent-loop.sh`. The script is organized into these sections:

1. **Global variables & system prompt** (top) — version, model, color codes, the prompt given to Claude; `load_boot_file` appends project context from `.agent-loop/boot.md` or a `<!-- boot: path -->` directive in the task file
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
- **Error classification & backoff**: `classify_error` categorizes failures (rate_limit, context_overflow, auth, timeout, network, unknown); `backoff_sleep` applies exponential backoff with jitter, doubled for rate limits
- **Model failover**: `--fallback-model` enables automatic switching between primary and fallback models on rate_limit or timeout errors
- **Context compaction**: when session token usage exceeds 80% of the context window, the session is summarized and a fresh session is started with the summary injected as context
- **Interrupt resume**: Ctrl+C saves partial context (extracted from `.result` in the JSON log) and marks the task as "interrupted"; re-running the command resumes from where it left off with the partial context as a hint

### Runtime directory structure

`.agent-loop/` is created in the target directory (the working directory, or `--dir <path>`):
- `state.json` — execution state
- `logs/NNN-group-slug--task-slug.log` — full Claude JSON output per task
- `boot.md` (optional) — project context appended to the system prompt for every task

## Additional Components

### `telegram-agent.py` + `requirements.txt`

A Python bot that exposes open-pulsar over Telegram. It long-polls the Telegram Bot API (no webhook required) and operates in three modes, switchable per-chat with `/mode`:

- **auto mode** (default) — uses Haiku to classify each message as chat or task and routes accordingly
- **chat mode** — forwards messages directly to `claude -p`, maintaining a per-chat session via `--resume`; SOUL.md content is prepended to the system prompt on session start
- **task mode** — writes the incoming message as a one-task markdown file and invokes `agent-loop.sh`, then replies with the result; supports `--soul-path` passthrough and reports soul evolution events

Bot commands: `/reset` (clear session), `/mode auto|chat|task`, `/status`, `/soul show|append|set`, `/help`.

**Config**: `.agent-loop/telegram.json` (copy from `.agent-loop/telegram.json.example`); token and allowed user IDs are read from a `.env` file via `python-dotenv`.

**Runtime files** (all under `.agent-loop/`):
- `telegram.json` — config (model, task_model, mode, system prompt, soul path, timeout)
- `telegram-sessions.json` — per-chat Claude session IDs (persisted across restarts)
- `telegram-state.json` — Telegram update offset (prevents reprocessing messages on restart)
- `telegram-tasks/` — ephemeral one-task markdown files written in task mode

**Dependencies** (`requirements.txt`): `requests>=2.31.0`, `python-dotenv>=1.0.0`.

```bash
pip install -r requirements.txt
python telegram-agent.py
```

## Dependencies

- bash 4+, jq, claude CLI (required)
- jj / Jujutsu (recommended, optional — graceful degradation)
- sha256sum (Linux standard; macOS needs `brew install coreutils`)

## Testing

Tests are bash scripts in `tests/` using simple pass/fail assertions (`assert_ok`, `assert_fail`, `assert_contains`). They test CLI flags, argument validation, dry-run parsing, state management, error classification, backoff, token extraction, boot file loading, and interrupt resume — not live Claude execution.

```bash
# Run all tests
bash tests/test-dir-flag.sh && bash tests/test-features.sh
```
