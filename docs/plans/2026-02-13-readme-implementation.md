# README Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a detailed README.md for the agent-loop project targeting developers who want to use the tool.

**Architecture:** Single markdown file at project root. Feature-first structure: intro, prerequisites, install, quick start, task file format, key concepts, CLI reference, examples, logs & debugging.

**Tech Stack:** Markdown

---

### Task 1: Write the README

**Files:**
- Create: `README.md`

**Step 1: Write the full README.md**

Write `README.md` with these sections in order:

**Header & Intro:**
```markdown
# agent-loop

A Bash tool that executes multi-step task lists autonomously using Claude Code CLI, with per-task version control isolation via Jujutsu.
```

Then a paragraph explaining the core workflow: write tasks in markdown organized by groups, agent-loop feeds them to Claude one by one. It tracks state in JSON, manages Claude sessions (context continuity within groups, fresh sessions across groups), isolates each task's changes using Jujutsu VCS, and employs AI-driven retry logic when tasks fail. Describe the result: you describe what you want built, agent-loop orchestrates an AI agent to build it step by step.

**Prerequisites:**

| Dependency | Required | Install |
|---|---|---|
| bash 4+ | Yes | Pre-installed on most systems |
| jq | Yes | `sudo apt install jq` / `brew install jq` |
| claude CLI | Yes | See [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) |
| jj (Jujutsu) | Recommended | See [jj install guide](https://jj-vcs.github.io/jj/latest/install-and-setup/) |

**Installation:**

```bash
git clone <repo-url>
cd agentic-loop
chmod +x agent-loop.sh
```

**Quick Start:**

Three steps:
1. Create `tasks.md`:
```markdown
## Setup
- Create a Python virtualenv and install flask
- Create a hello world Flask app in app.py
```
2. Preview: `./agent-loop.sh --dry-run tasks.md`
3. Execute: `./agent-loop.sh tasks.md`

**Task File Format:**

Explain the markdown format:
- `## Heading` creates a task group
- `- Task description` defines a task
- Multi-line tasks via indentation
- Blank lines are ignored

Show the sample-tasks.md as a realistic example. Explain that groups control session behavior: first task in a group starts a fresh Claude session, subsequent tasks in the same group resume it (maintaining context), and a new group starts a new session.

**Key Concepts — Session Management:**

Explain the three session rules:
1. First task in a group → fresh Claude session
2. Subsequent tasks in same group → resume session (context carries over)
3. New group → fresh session (isolation)

Explain why this matters: tasks in the same group share context so later tasks can reference work done by earlier ones. Groups provide isolation so unrelated work doesn't pollute each other's context.

**Key Concepts — Jujutsu VCS Integration:**

Full section covering:
- What it does: creates a separate jj change (similar to a git commit) per task, giving fine-grained revertability
- Auto-initialization: if jj isn't set up in the target directory, agent-loop initializes it automatically (with git colocate if a .git dir exists)
- Per-task isolation: each task gets its own change; if a task fails, its change is automatically abandoned (rolled back)
- Graceful degradation: if jj isn't installed, agent-loop warns and proceeds without version control isolation
- Retries: on retry, the previous attempt's change is abandoned and a new one created

**Key Concepts — State Persistence:**

Explain `.agent-loop/state.json`:
- Tracks each task's status (pending, running, completed, failed), session ID, jj change ID, attempt count
- Enables resume: re-running the same command continues from where it left off
- File hash integrity: if the task file changes between runs, execution stops and requires `--reset`
- State directory also contains per-task logs

**Key Concepts — AI-Driven Retry Logic:**

Explain the retry system:
- When a task fails, Claude Haiku analyzes the error output
- Haiku decides whether retrying would help and provides a hint for the next attempt
- Hints are injected into the retry prompt so Claude can approach the problem differently
- Hard limit of 5 attempts per task
- Failed tasks don't block subsequent tasks

**CLI Reference:**

```
Usage: agent-loop.sh [options] <tasks.md>
```

| Flag | Description | Default |
|---|---|---|
| `--model <model>` | Claude model to use | `opus` |
| `--dir <path>` | Target directory for task execution | Current directory |
| `--dry-run` | Parse and display tasks without executing | |
| `--reset` | Clear state file and start fresh | |
| `--status` | Show progress of current task file | |
| `--help` | Show help message | |
| `--version` | Show version | |

**Examples:**

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

**Logs & Debugging:**

Explain:
- Logs stored in `.agent-loop/logs/`
- Naming convention: `NNN-group-slug--task-slug.log` (e.g., `001-backend-api--create-a-rest-api-with-endpoints-for-users-crud.log`)
- Each log contains Claude's full JSON output for that task
- State file at `.agent-loop/state.json` shows status of all tasks
- Use `--status` for a quick progress summary

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage guide"
```
