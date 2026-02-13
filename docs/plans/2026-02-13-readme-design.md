# README Design

## Audience
Developers who want to use agent-loop to automate multi-step tasks with Claude Code.

## Tone
Detailed and explanatory — explain concepts (task groups, sessions, jj integration) in depth with examples.

## Structure (Approach A: Feature-first)

### 1. Header & Intro
- Title: `agent-loop`
- Tagline: Bash tool that executes multi-step task lists autonomously using Claude Code CLI, with per-task version control isolation via Jujutsu.
- Intro paragraph: core workflow — write tasks in markdown, agent-loop feeds them to Claude one by one. Tracks state, manages sessions (context continuity within groups, fresh sessions across groups), isolates changes per-task with Jujutsu, AI-driven retry on failure.

### 2. Prerequisites
- bash 4+
- jq
- claude CLI (Claude Code)
- jj (Jujutsu) — optional but recommended
- sha256sum — standard on Linux

### 3. Installation
Clone and chmod +x. No build step.

### 4. Quick Start
Three steps:
1. Create a sample tasks.md
2. Dry-run: `./agent-loop.sh --dry-run tasks.md`
3. Execute: `./agent-loop.sh tasks.md`

### 5. Task File Format
- `## Heading` creates groups (with session behavior)
- `- Task text` defines tasks
- Multi-line continuation via indentation
- Realistic multi-group example

### 6. Key Concepts
Sub-sections:
- **Session Management** — first task fresh, subsequent resume, new group fresh
- **Jujutsu VCS Integration** — full section: auto-init, per-task changes, failed rollback, graceful degradation
- **State Persistence** — state.json, resume, file hash integrity
- **AI-Driven Retry Logic** — Haiku analysis, retry decision with hints, 5-attempt limit

### 7. CLI Reference
All flags with descriptions and defaults:
- `--model <model>` (default: opus)
- `--dir <path>` (default: cwd)
- `--dry-run`
- `--reset`
- `--status`
- `--help`
- `--version`

### 8. Examples
- Running against another project with `--dir`
- Checking progress with `--status`
- Resetting after task file changes
- Using different models

### 9. Logs & Debugging
- Log location: `.agent-loop/logs/`
- Naming convention: `NNN-group-slug--task-slug.log`
- How to inspect Claude output
