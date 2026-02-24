## Teams Agent

- Study telegram-agent.py and instagram-agent.py in full to understand the session management, config loading, Claude invocation, command handling, and chunking patterns used across both agents. Do not write any code yet.

- Implement teams-agent.py using the Microsoft Graph API polling approach (no webhook, no Azure Bot Framework). The agent should: load config from .agent-loop/teams.json (with keys: client_id_env, client_secret_env, tenant_id_env, allowed_user_ids, mode, model, poll_interval_seconds, task_timeout_seconds, system_prompt); authenticate via OAuth2 client credentials flow and auto-refresh tokens; poll /me/chats and /chats/{id}/messages using Microsoft Graph; support chat and task modes with the same slash commands as the Telegram agent (/reset, /mode, /status, /help); reuse the same run_claude_chat and queue_agent_loop_task patterns from telegram-agent.py; chunk long replies at 4000 characters (Teams limit). Use only requests and msal Python libraries plus python-dotenv.

- Create .agent-loop/teams.json.example with all config keys and inline comments explaining each one. Update requirements.txt to add msal. Update .gitignore to exclude .agent-loop/teams-sessions.json and .agent-loop/teams-state.json. Add a Teams Integration section to README.md following the same structure as the Telegram and Instagram sections.
