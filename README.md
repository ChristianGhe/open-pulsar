# agent-loop

**A Bash tool that executes multi-step task lists autonomously using Claude Code CLI, with per-task version control isolation via Jujutsu.**

You write tasks in a markdown file, organized into groups. agent-loop feeds them to Claude one by one, tracking state in a JSON file so runs can be interrupted and resumed. It manages Claude sessions automatically — tasks within the same group share a session so context carries over, while a new group starts a fresh session for isolation. Each task's changes are isolated using Jujutsu VCS, giving you fine-grained revertability at the task level. When a task fails, AI-driven retry logic analyzes the error and decides whether to try again, injecting hints so Claude approaches the problem differently on the next attempt. The result: you describe what you want built, and agent-loop orchestrates an AI agent to build it step by step.

## Prerequisites

| Dependency | Required | Install |
|---|---|---|
| bash 4+ | Yes | Pre-installed on most systems |
| jq | Yes | `sudo apt install jq` / `brew install jq` |
| claude CLI (Claude Code) | Yes | See [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) |
| jj (Jujutsu) | Recommended | See [jj install guide](https://jj-vcs.github.io/jj/latest/install-and-setup/) |

## Installation

```bash
git clone <repo-url>
cd agentic-loop
chmod +x agent-loop.sh
```

## Quick Start

1. **Create a `tasks.md`** describing what you want built:

```markdown
## Setup
- Create a Python virtualenv and install flask
- Create a hello world Flask app in app.py
```

2. **Preview** what agent-loop will do (no execution, just parsing):

```bash
./agent-loop.sh --dry-run tasks.md
```

3. **Execute** the tasks:

```bash
./agent-loop.sh tasks.md
```

agent-loop will work through each task sequentially, showing progress in the terminal. You can interrupt at any time with Ctrl+C and resume later by running the same command again.

## Task File Format

Tasks are defined in a markdown file using a simple format:

- **`## Heading`** creates a task group. Groups control how Claude sessions are managed (see [Session Management](#session-management) below).
- **`- Task description`** defines a task. Each bullet point is one unit of work that Claude will execute.
- **Multi-line tasks** are supported via indentation. If lines following a task bullet are indented, they are treated as continuation lines and appended to the task description.
- **Blank lines and non-task lines** (anything that isn't a heading or a bullet) are ignored.

Here is a realistic multi-group example:

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

Groups are more than just organizational labels — they control session behavior. Tasks within the same group share a Claude session, which means Claude retains context from earlier tasks in that group. When a new group begins, a fresh session starts. This is explained in detail in the next section.

## Key Concepts

### Session Management

agent-loop manages Claude sessions using three rules:

1. **First task in a group** starts a fresh Claude session. Claude begins with no prior context.
2. **Subsequent tasks in the same group** resume the existing session. Claude retains full context from previous tasks in the group, so it can reference files it created, decisions it made, and patterns it established.
3. **New group** starts a fresh session. Claude begins clean, with no memory of previous groups.

This matters because context continuity within a group means later tasks can build on earlier ones naturally. For example, if the first task in a "Backend API" group creates a database schema, the second task can reference that schema without re-explaining it. Groups provide isolation so that unrelated work (like frontend tasks) doesn't pollute Claude's context with irrelevant backend details, keeping the AI focused and reducing the chance of confusion.

### Jujutsu VCS Integration

agent-loop uses [Jujutsu](https://jj-vcs.github.io/jj/) (jj) to provide per-task version control isolation. This gives you fine-grained revertability — each task gets its own jj change (similar to a git commit), so you can inspect, revert, or cherry-pick individual task results.

**Auto-initialization:** If Jujutsu isn't already set up in the target directory, agent-loop initializes it automatically. If a `.git` directory exists, it uses `jj git init --colocate` so Jujutsu works alongside your existing Git repository. Otherwise, it creates a standalone Jujutsu repo with `jj init`.

**Per-task isolation:** Before executing each task, agent-loop creates a new jj change with a descriptive message (e.g., `agent-loop: Backend API / Create a REST API with endpoints for users CRUD`). All file modifications Claude makes during that task are captured in that change. If a task fails, its change is automatically abandoned (rolled back), so failed work doesn't litter your repository.

**Retries:** When a task is retried, the previous attempt's jj change is abandoned and a new change is created for the fresh attempt. This means only the successful attempt's changes survive.

**Graceful degradation:** If jj isn't installed, agent-loop prints a warning and continues without version control isolation. Everything else works normally — you just lose per-task revertability. This makes jj recommended but not required.

### State Persistence

agent-loop tracks execution state in `.agent-loop/state.json` within the target directory. This file records:

- **Task status**: Each task is tracked as `pending`, `running`, `completed`, or `failed`.
- **Session IDs**: The Claude session ID associated with each task, enabling session continuity within groups.
- **Jujutsu change IDs**: The jj change ID for each task, linking tasks to their version control changes.
- **Attempt count**: How many times each task has been attempted.

**Resuming:** If a run is interrupted (Ctrl+C, crash, or system restart), simply re-run the same command. agent-loop reads the state file and picks up where it left off, skipping tasks that are already completed or failed.

**File hash integrity:** When agent-loop first processes a task file, it stores a SHA-256 hash of the file contents. On subsequent runs, it compares the current hash against the stored one. If the task file has been modified between runs, execution stops and you must run `--reset` to clear the state and start fresh. This prevents confusion from running a modified task list against stale state.

**State directory:** The `.agent-loop/` directory also contains per-task logs in the `logs/` subdirectory (see [Logs & Debugging](#logs--debugging) below).

### AI-Driven Retry Logic

When a task fails, agent-loop doesn't just retry blindly. It uses Claude Haiku (a fast, inexpensive model) to analyze the error output and make an intelligent decision:

1. **Failure analysis**: Haiku examines the task description and the error output from the failed attempt.
2. **Retry decision**: Haiku decides whether retrying would be productive. Some failures (like a missing dependency) might be recoverable, while others (like a fundamentally impossible task) are not.
3. **Hint injection**: If Haiku recommends a retry, it provides a specific hint describing what went wrong and how to approach the task differently. This hint is injected into the retry prompt so that Claude sees it and can adjust its strategy.
4. **Hard limit**: Each task is attempted a maximum of 5 times. After that, the task is marked as failed regardless of analysis.
5. **Non-blocking**: Failed tasks don't block subsequent tasks. agent-loop moves on to the next task, so a single failure doesn't halt the entire run.

## CLI Reference

```
Usage: agent-loop.sh [options] <tasks.md>
```

| Flag | Description | Default |
|---|---|---|
| `--model <model>` | Claude model to use | `opus` |
| `--dir <path>` | Target directory for task execution | Current directory |
| `--dry-run` | Parse and display tasks without executing | — |
| `--reset` | Clear state file and start fresh | — |
| `--status` | Show progress of current task file | — |
| `--help` | Show help message | — |
| `--version` | Show version | — |

## Examples

```bash
# Preview tasks before running
./agent-loop.sh --dry-run tasks.md

# Execute with a specific model
./agent-loop.sh --model sonnet tasks.md

# Run tasks against a different project
./agent-loop.sh --dir ~/projects/my-app tasks.md

# Check progress mid-run (from another terminal)
./agent-loop.sh --status

# Start over after editing the task file
./agent-loop.sh --reset
./agent-loop.sh tasks.md
```

## Logs & Debugging

agent-loop stores detailed logs for every task execution in `.agent-loop/logs/`.

**Naming convention:** Log files follow the pattern `NNN-group-slug--task-slug.log`, where `NNN` is the zero-padded task number, `group-slug` is the slugified group name, and `task-slug` is the slugified task description (truncated to 50 characters). For example:

```
001-backend-api--create-a-rest-api-with-endpoints-for-users-crud.log
```

**Contents:** Each log file contains Claude's full JSON output for that task, including the complete conversation, tool calls, and results. This is invaluable for understanding what Claude did, diagnosing failures, and debugging unexpected behavior.

**State file:** The state file at `.agent-loop/state.json` shows the status of all tasks at a glance — their current status, session IDs, jj change IDs, and attempt counts.

**Quick status check:** Use `--status` for a human-readable progress summary without needing to parse JSON:

```bash
./agent-loop.sh --status
```

This prints the task file name, overall progress counts, and the status of each individual task.
