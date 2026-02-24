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

> **macOS note:** agent-loop uses `sha256sum` for file integrity checks, which is not included in macOS by default. Install GNU coreutils: `brew install coreutils`.

## Installation

```bash
git clone <repo-url>
cd agentic-loop
chmod +x agent-loop.sh
```

## Docker

Build an image with all runtime dependencies (including the native Claude Code CLI):

```bash
docker build -t agent-loop .
```

Run agent-loop against your current directory:

```bash
docker run --rm -it \
  -v "$PWD:/workspace" \
  -w /workspace \
  -e ANTHROPIC_API_KEY \
  agent-loop --dry-run tasks.md
```

## Telegram Integration (recommended)

`telegram-agent.py` lets you communicate with Claude remotely via Telegram — using the official Bot API with no session management, no cookies, and no account lockouts.

### Setup

1. **Create a bot** — open Telegram, message `@BotFather`, send `/newbot`, follow prompts, copy the token.

2. **Get your user ID** — message `@userinfobot` on Telegram, copy the numeric ID.

3. **Add to `.env`:**

```bash
telegram_token=123456789:AAF-your-token-here
telegram_allowed_ids=987654321
```

4. **Create the config:**

```bash
cp .agent-loop/telegram.json.example .agent-loop/telegram.json
```

5. **Run:**

```bash
python telegram-agent.py
```

The agent connects instantly, logs `Connected as @yourbotname`, and starts listening. Send it a message — Claude replies in seconds.

### Modes

| Mode | Behavior |
|------|----------|
| `chat` (default) | Messages go directly to Claude. Each Telegram chat maintains its own Claude session. |
| `task` | Each message is treated as a task description, executed via `agent-loop.sh`, result sent back. |

Switch with `/mode chat` or `/mode task`.

### Commands

| Command | Description |
|---------|-------------|
| `/reset` | Clear the Claude session for this chat |
| `/mode chat` | Switch to direct Claude chat |
| `/mode task` | Switch to task execution via agent-loop.sh |
| `/status` | Show current mode, model, session count |
| `/help` | List available commands |

### Configuration reference

`.agent-loop/telegram.json`:

| Key | Default | Description |
|-----|---------|-------------|
| `token_env` | `telegram_token` | Env var name for the bot token |
| `allowed_ids_env` | `telegram_allowed_ids` | Env var name for allowed user IDs (comma-separated) |
| `mode` | `chat` | Default mode: `chat` or `task` |
| `model` | `sonnet` | Claude model |
| `system_prompt` | *(built-in)* | System prompt for Claude in chat mode |
| `task_timeout_seconds` | `600` | Timeout for agent-loop.sh in task mode |

---

## Instagram DM Integration (optional)

`instagram-agent.py` lets you communicate with Claude remotely via Instagram DMs — no backend server or webhooks required. The script polls your DMs, forwards messages to Claude, and replies with the response.

### Setup

1. Create a dedicated Instagram account for the agent (recommended), or use an existing one.

2. Install the Python dependency:

```bash
pip install -r requirements.txt
```

3. Create the config file:

```bash
cp .agent-loop/instagram.json.example .agent-loop/instagram.json
# Edit allowed_senders to include your own Instagram username
```

4. Set credentials as environment variables (never store them in the config):

```bash
export IG_USERNAME="the_agent_account_username"
export IG_PASSWORD="the_agent_account_password"
```

5. Run the agent:

```bash
python instagram-agent.py
```

The agent will log in, then poll your DMs every 30 seconds (configurable). Send a DM from an account listed in `allowed_senders` and Claude will reply.

### Modes

| Mode | Behavior |
|------|----------|
| `chat` (default) | DMs are forwarded directly to Claude. Each Instagram thread maintains its own Claude session — full conversational continuity. |
| `task` | Each DM is treated as a task description, written to a task file, and executed via `agent-loop.sh`. The result is sent back as a DM. |

Switch modes mid-conversation by DMing `/mode chat` or `/mode task`. The switch is in-memory only and resets on script restart.

### Slash Commands

| Command | Description |
|---------|-------------|
| `/reset` | Clear the Claude session for this thread and start fresh |
| `/mode chat` | Switch to direct Claude chat |
| `/mode task` | Switch to task execution via agent-loop.sh |
| `/status` | Show current mode, model, and active session count |
| `/help` | List available commands |

### Long Responses

Instagram has a 1000-character message limit. Long Claude responses are automatically split at paragraph/sentence boundaries into labeled chunks: `[1/3]`, `[2/3]`, `[3/3]`.

### Configuration Reference

`.agent-loop/instagram.json` (safe to commit — no credentials stored):

| Key | Default | Description |
|-----|---------|-------------|
| `username_env` | `IG_USERNAME` | Env var name for the Instagram username |
| `password_env` | `IG_PASSWORD` | Env var name for the Instagram password |
| `allowed_senders` | `[]` | Instagram usernames permitted to trigger Claude. Empty = anyone (not recommended) |
| `mode` | `chat` | Default mode: `chat` or `task` |
| `model` | `sonnet` | Claude model to use |
| `system_prompt` | *(built-in)* | System prompt for Claude in chat mode |
| `poll_interval_seconds` | `30` | Seconds between DM polls |
| `task_timeout_seconds` | `600` | Timeout for agent-loop.sh in task mode |

### Security Notes

- Only accounts listed in `allowed_senders` can trigger Claude. Keep this list to yourself and trusted accounts.
- Credentials are read from environment variables; the config file never contains passwords.
- The session cache (`.agent-loop/instagram-session-cache.json`) contains auth tokens — it is gitignored automatically.
- This integration uses [instagrapi](https://github.com/subzeroid/instagrapi), an **unofficial** library that works with any personal Instagram account but violates Instagram's Terms of Service. Your account may be restricted. Use a dedicated agent account at your own risk.

## Microsoft Teams Integration (optional)

`teams-agent.py` lets you communicate with Claude remotely via Microsoft Teams DMs — using the official Microsoft Graph API with client-credentials OAuth2, no browser sessions, and no unofficial libraries.

### Setup

1. **Register an Azure AD app:**
   - Go to [Azure Portal](https://portal.azure.com) → **App registrations** → **New registration**.
   - Give it a name (e.g. `claude-teams-agent`), leave defaults, click **Register**.
   - Note the **Application (client) ID** and **Directory (tenant) ID** from the Overview page.

2. **Add Graph permissions:**
   - In the app, go to **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**.
   - Add `Chat.ReadWrite.All`.
   - Click **Grant admin consent** (requires a Global Admin or Privileged Role Admin account).

3. **Create a client secret:**
   - Go to **Certificates & secrets** → **New client secret**.
   - Copy the **Value** immediately — it is only shown once.

4. **Find the monitored user's Object ID:**
   - Go to **Azure Portal** → **Users** → select the account you want to monitor → copy the **Object ID**.

5. **Add credentials to `.env`:**

```bash
TEAMS_CLIENT_ID=your-application-client-id
TEAMS_CLIENT_SECRET=your-client-secret-value
TEAMS_TENANT_ID=your-directory-tenant-id
TEAMS_USER_ID=object-id-of-user-to-monitor
```

6. **Create the config:**

```bash
cp .agent-loop/teams.json.example .agent-loop/teams.json
# Edit allowed_user_ids to include the Object ID of senders you trust
```

7. **Install dependencies:**

```bash
pip install -r requirements.txt
```

8. **Run:**

```bash
python teams-agent.py
```

The agent validates the token and monitored user on startup, then begins polling for new 1:1 chat messages every 30 seconds (configurable). Send a Teams DM to the monitored account from a permitted user — Claude replies within one poll interval.

### Modes

| Mode | Behavior |
|------|----------|
| `chat` (default) | Messages go directly to Claude. Each Teams chat maintains its own Claude session — full conversational continuity. |
| `task` | Each message is treated as a task description, executed via `agent-loop.sh`, result sent back. |

Switch modes mid-conversation with `/mode chat` or `/mode task`. The switch is in-memory only and resets on script restart.

### Slash Commands

| Command | Description |
|---------|-------------|
| `/reset` | Clear the Claude session for this chat and start fresh |
| `/mode chat` | Switch to direct Claude chat |
| `/mode task` | Switch to task execution via agent-loop.sh |
| `/status` | Show current mode, model, and active session count |
| `/help` | List available commands |

### Long Responses

Microsoft Teams has a practical message-length limit. Long Claude responses are automatically split at paragraph/sentence boundaries into labeled chunks: `[1/3]`, `[2/3]`, `[3/3]`, with a 0.5-second delay between chunks to avoid rate limiting.

### Configuration Reference

`.agent-loop/teams.json` (safe to commit — no credentials stored):

| Key | Default | Description |
|-----|---------|-------------|
| `client_id_env` | `TEAMS_CLIENT_ID` | Env var name for the Azure app's Application (client) ID |
| `client_secret_env` | `TEAMS_CLIENT_SECRET` | Env var name for the Azure app's client secret |
| `tenant_id_env` | `TEAMS_TENANT_ID` | Env var name for the Azure Directory (tenant) ID |
| `user_id_env` | `TEAMS_USER_ID` | Env var name for the Object ID of the Teams user to monitor |
| `allowed_user_ids` | `[]` | Object IDs of Teams users permitted to trigger Claude. Empty = anyone (not recommended) |
| `mode` | `chat` | Default mode: `chat` or `task` |
| `model` | `sonnet` | Claude model to use |
| `system_prompt` | *(built-in)* | System prompt for Claude in chat mode |
| `poll_interval_seconds` | `30` | Seconds between Graph API polls |
| `task_timeout_seconds` | `600` | Timeout for agent-loop.sh in task mode |

### Security Notes

- Only users listed in `allowed_user_ids` can trigger Claude. Set this to your own Object ID.
- Credentials are read from environment variables; the config file never contains secrets.
- The session and state caches (`.agent-loop/teams-sessions.json`, `.agent-loop/teams-state.json`) contain auth tokens and conversation history — they are gitignored automatically.
- `Chat.ReadWrite.All` is an **application permission** (not delegated). It grants the app access to chats for the monitored user at the tenant level and requires explicit admin consent. Use a dedicated service account as the monitored user and limit `allowed_user_ids` accordingly.
- Access tokens are cached in memory and refreshed automatically via MSAL; you do not need to handle token expiry manually.

---

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

# Check progress when using --dir
./agent-loop.sh --dir ~/projects/my-app --status

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
