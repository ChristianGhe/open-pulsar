# Design: --dir flag for target folder execution

## Overview

Add a `--dir <path>` option to `agent-loop.sh` so the agent can be pointed at any project folder. Claude executes tasks in the target directory, state and logs live in `<target>/.agent-loop/`, and Jujutsu isolation applies to the target folder.

## Interface

```
agent-loop.sh [options] <tasks.md>

  --dir <path>    Target directory for task execution (default: current directory)
```

Example:
```bash
./agent-loop.sh --dir /home/user/my-project tasks.md
```

The task file path is resolved relative to where you run the command (or absolute). The `--dir` path is where Claude does its work.

## Behavior

When `--dir /some/project` is passed:

1. **Path resolution** -- resolve to absolute path at parse time
2. **State in target** -- `.agent-loop/` directory lives in the target folder
3. **Jujutsu in target** -- auto-init and per-task changes happen in the target folder
4. **Claude works in target** -- Claude's working directory is the target folder
5. **`--reset`/`--status`** -- operate on `<target>/.agent-loop/` when `--dir` is specified
6. **Default preserved** -- if `--dir` omitted, works exactly as before (uses `$(pwd)`)

## Implementation changes

### A. New global variable

```bash
TARGET_DIR=""  # Set by --dir, defaults to $(pwd) in main()
```

### B. Argument parsing

Add `--dir` case in `parse_args()`. Validates directory exists, resolves to absolute path.

### C. Path derivation

After `parse_args`, derive all paths from `TARGET_DIR`:
```bash
TARGET_DIR="${TARGET_DIR:-$(pwd)}"
STATE_DIR="$TARGET_DIR/.agent-loop"
STATE_FILE="$STATE_DIR/state.json"
LOG_DIR="$STATE_DIR/logs"
```

### D. Claude invocation

In `run_claude()`, run Claude from the target dir using a subshell:
```bash
output=$(cd "$TARGET_DIR" && CLAUDECODE= claude ... "$prompt" 2>&1)
```

### E. Jujutsu operations

All jj commands (`ensure_jj`, `jj_new_change`, `jj_abandon_change`) run from the target dir via subshell.

### F. Deferred --reset/--status

Currently `--reset` and `--status` exit immediately during argument parsing. They need to be deferred so `--dir` is parsed first.

### G. UI updates

- Usage text includes `--dir <path>`
- Banner shows target directory when set
- Summary shows target directory

## What doesn't change

Task file parsing, state format, retry logic, session management, system prompt -- all core logic stays the same. Only the working directory context changes.
