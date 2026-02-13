# Agentic Loop Design

## Overview

A Bash script (`agent-loop.sh`) that reads a markdown task file and executes each task autonomously using Claude Code CLI (`claude -p`). Tasks are grouped by markdown headings — tasks within a group share a Claude session for context continuity, while groups get fresh sessions. Each task's file changes are isolated in a Jujutsu (`jj`) change for easy revertability.

## Task File Format

File: `tasks.md` (or any `.md` file passed as argument)

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

**Parsing rules:**
- `## Heading` lines define **groups** (new Claude session per group)
- `- Task text` lines define **individual tasks** (one `claude -p` invocation each)
- Task text can span multiple lines if continuation lines are indented
- All other lines are ignored (comments, notes, blank lines)

## Script Interface

```
agent-loop.sh [options] <tasks.md>

Options:
  --model <model>       Claude model to use (default: opus)
  --dry-run             Parse and show tasks without executing
  --reset               Clear state file and start fresh
  --status              Show progress of current task file
```

## Architecture

### Core Flow

1. **Parse** the task file into groups and tasks
2. **Load state** from `.agent-loop/state.json` (tracks completed tasks)
3. **Check jj**: if not initialized, auto-run `jj git init` (if git repo) or `jj init`
4. **For each group:**
   - Skip fully-completed groups
   - First uncompleted task: `claude -p` (fresh session), capture session ID from JSON output
   - Subsequent tasks: `claude -p --resume <session-id>` (shared session)
   - Before each task: `jj new -m "agent-loop: <group> / <task-summary>"`
   - After each task: save output to log, update state
5. **On completion**: print summary

### Session Management

- First task in a group: fresh session via `claude -p --output-format json`
- Session ID extracted from JSON response
- Subsequent tasks in group: `claude -p --resume <session-id>`
- Between groups: no `--resume` (clean slate)

### Claude Invocation

**System prompt:**
```
You are an autonomous agent executing tasks from a task list.
Use ALL tools available to you to complete the task thoroughly.
Work in the current directory. Do not ask questions — make reasonable decisions and proceed.
If a task is ambiguous, interpret it in the most useful way and execute.
Commit nothing to git/jj — the outer loop handles version control.
```

**First task in group:**
```bash
claude -p \
  --dangerously-skip-permissions \
  --model "$MODEL" \
  --system-prompt "$SYSTEM_PROMPT" \
  --output-format json \
  "$task_text"
```

**Subsequent tasks in group:**
```bash
claude -p \
  --dangerously-skip-permissions \
  --model "$MODEL" \
  --resume "$session_id" \
  "$task_text"
```

## Jujutsu Integration

**Before each task:**
```bash
jj new -m "agent-loop: <group-name> / <task-summary>"
```

**Auto-initialization:** If `jj root` fails:
- If `.git/` exists: run `jj git init`
- Otherwise: run `jj init`

**Revert a task:**
```bash
jj abandon <change-id>    # discard changes
jj backout -r <change-id> # reverse changes
```

**State file location:** `.agent-loop/` directory (outside jj tracking via `.gitignore`) so that abandoning changes doesn't lose progress state.

## Logging & State

### Directory Structure

```
.agent-loop/
  state.json
  logs/
    001-backend-api--create-rest-api.log
    002-backend-api--add-auth-middleware.log
    ...
```

### State File (`state.json`)

```json
{
  "task_file": "tasks.md",
  "task_file_hash": "sha256:...",
  "started_at": "2026-02-13T10:00:00Z",
  "tasks": [
    {
      "index": 1,
      "group": "Backend API",
      "task": "Create a REST API with endpoints for users CRUD",
      "status": "completed",
      "session_id": "uuid",
      "jj_change": "abc123",
      "log": "001-backend-api--create-rest-api.log",
      "attempts": 1
    }
  ]
}
```

### Console Output

```
[1/7] Backend API > Create a REST API with endpoints for users CRUD
  jj: created change abc1234
  claude: running... (output -> .agent-loop/logs/001-backend-api--create-rest-api.log)
  completed in session sess_abc123

[2/7] Backend API > Add authentication middleware using JWT
  jj: created change def5678
  claude: running... (resuming session sess_abc123)
  ...
```

## Error Handling

### AI-Driven Retry

On task failure:
1. Capture error output
2. Invoke Claude in a fresh lightweight session with the error, asking for JSON response: `{"retry": true/false, "reason": "...", "hint": "..."}`
3. If `retry=true`: abandon the failed jj change, create new change, re-run with hint appended to prompt
4. If `retry=false`: mark as `"failed"`, abandon jj change, continue to next task
5. **Hard cap: 5 total attempts** regardless of AI decision

### Session Chain on Failure

A failed task (after exhausting retries) breaks the session chain. The next task in the same group starts a fresh session instead of resuming the broken one.

### Interrupted Runs (Ctrl+C)

- State file updated after each completed task
- Trap handler for clean shutdown
- Re-running the script resumes from last completed task

### Task File Changes

- State file stores SHA-256 hash of the task file
- If hash differs on resume: warn user, require `--reset` to continue

## File Inventory

```
agent-loop.sh         # Main script (executable)
.agent-loop/          # Runtime data (gitignored)
  state.json          # Progress tracking
  logs/               # Per-task output logs
.gitignore            # Ensures .agent-loop/ is ignored
```
