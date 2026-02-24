#!/usr/bin/env python3
"""
teams-agent.py — Remote communication with Claude via Microsoft Teams.

Polls Teams direct-message chats via Microsoft Graph API and forwards
messages to Claude (claude -p). Replies with Claude's response.
No webhooks or Azure Bot Framework required.

Setup:
    1. Register an Azure AD app (Azure Portal → App Registrations → New)
    2. Under "API permissions" add application permissions:
           Chat.ReadWrite.All
    3. Grant admin consent for those permissions
    4. Under "Certificates & secrets" create a client secret
    5. Add to .env:
           TEAMS_CLIENT_ID=<app-client-id>
           TEAMS_CLIENT_SECRET=<client-secret-value>
           TEAMS_TENANT_ID=<azure-tenant-id>
           TEAMS_USER_ID=<object-id-of-the-Teams-user-to-monitor>
    6. cp .agent-loop/teams.json.example .agent-loop/teams.json
    7. Edit allowed_user_ids with the object IDs of permitted senders
    8. python teams-agent.py

Note on TEAMS_USER_ID: because this agent uses the OAuth2 client-credentials
flow (app-only auth, no user session), Graph API /me/ is unavailable. The
user_id_env value identifies the Teams user whose 1-on-1 chats are monitored.
Obtain it from: Azure Portal → Users → <user> → Object ID.

Config: .agent-loop/teams.json
"""

import html
import json
import logging
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    print("Error: python-dotenv not installed. Run: pip install -r requirements.txt",
          file=sys.stderr)
    sys.exit(1)

try:
    import requests
except ImportError:
    print("Error: requests not installed. Run: pip install -r requirements.txt",
          file=sys.stderr)
    sys.exit(1)

try:
    import msal
except ImportError:
    print("Error: msal not installed. Run: pip install -r requirements.txt",
          file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

AGENT_DIR = Path(".agent-loop")
CONFIG_PATH = AGENT_DIR / "teams.json"
SESSIONS_PATH = AGENT_DIR / "teams-sessions.json"
STATE_PATH = AGENT_DIR / "teams-state.json"

GRAPH_BASE = "https://graph.microsoft.com/v1.0"
_GRAPH_SCOPES = ["https://graph.microsoft.com/.default"]


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(
            f"Error: {CONFIG_PATH} not found.\n"
            "  cp .agent-loop/teams.json.example .agent-loop/teams.json",
            file=sys.stderr,
        )
        sys.exit(1)

    with CONFIG_PATH.open() as f:
        cfg = json.load(f)

    client_id_env     = cfg.get("client_id_env",     "TEAMS_CLIENT_ID")
    client_secret_env = cfg.get("client_secret_env", "TEAMS_CLIENT_SECRET")
    tenant_id_env     = cfg.get("tenant_id_env",     "TEAMS_TENANT_ID")
    user_id_env       = cfg.get("user_id_env",       "TEAMS_USER_ID")

    cfg["_client_id"]     = os.environ.get(client_id_env, "")
    cfg["_client_secret"] = os.environ.get(client_secret_env, "")
    cfg["_tenant_id"]     = os.environ.get(tenant_id_env, "")
    cfg["_user_id"]       = os.environ.get(user_id_env, "")

    missing = []
    if not cfg["_client_id"]:
        missing.append(f"${client_id_env}")
    if not cfg["_client_secret"]:
        missing.append(f"${client_secret_env}")
    if not cfg["_tenant_id"]:
        missing.append(f"${tenant_id_env}")
    if not cfg["_user_id"]:
        missing.append(f"${user_id_env}")
    if missing:
        print(f"Error: Set {', '.join(missing)} in your .env file.", file=sys.stderr)
        sys.exit(1)

    if not cfg.get("allowed_user_ids"):
        logging.warning(
            "SECURITY WARNING: allowed_user_ids is empty — "
            "any Teams user can trigger Claude. Set it in .agent-loop/teams.json."
        )

    return cfg


# ---------------------------------------------------------------------------
# MSAL / OAuth2 token management (client credentials, app-only)
# ---------------------------------------------------------------------------

_msal_app: "msal.ConfidentialClientApplication | None" = None


def _get_msal_app(cfg: dict) -> "msal.ConfidentialClientApplication":
    global _msal_app
    if _msal_app is None:
        authority = f"https://login.microsoftonline.com/{cfg['_tenant_id']}"
        _msal_app = msal.ConfidentialClientApplication(
            client_id=cfg["_client_id"],
            client_credential=cfg["_client_secret"],
            authority=authority,
        )
    return _msal_app


def get_access_token(cfg: dict) -> str:
    """Return a valid access token, using MSAL's in-memory cache.

    MSAL automatically returns the cached token when it is still valid and
    acquires a fresh one (via client credentials) when it has expired — so
    callers never need to manage refresh manually.
    """
    app = _get_msal_app(cfg)
    # Try the cache first (returns None when empty or expired)
    result = app.acquire_token_silent(_GRAPH_SCOPES, account=None)
    if not result:
        result = app.acquire_token_for_client(scopes=_GRAPH_SCOPES)

    if "access_token" in result:
        return result["access_token"]

    error = result.get("error", "unknown")
    description = result.get("error_description", "")
    raise RuntimeError(f"MSAL token acquisition failed: {error} — {description}")


# ---------------------------------------------------------------------------
# Microsoft Graph API helpers
# ---------------------------------------------------------------------------

def graph_get(cfg: dict, path: str, params: dict | None = None) -> dict:
    """GET from the Graph API. Returns parsed JSON or raises RuntimeError."""
    token = get_access_token(cfg)
    try:
        r = requests.get(
            f"{GRAPH_BASE}{path}",
            headers={"Authorization": f"Bearer {token}"},
            params=params,
            timeout=20,
        )
    except Exception as e:
        raise RuntimeError(f"Graph GET {path} network error: {e}") from e

    if not r.ok:
        raise RuntimeError(
            f"Graph GET {path} returned {r.status_code}: {r.text[:200]}"
        )
    return r.json()


def graph_post(cfg: dict, path: str, body: dict) -> dict:
    """POST to the Graph API. Returns parsed JSON or raises RuntimeError."""
    token = get_access_token(cfg)
    try:
        r = requests.post(
            f"{GRAPH_BASE}{path}",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=20,
        )
    except Exception as e:
        raise RuntimeError(f"Graph POST {path} network error: {e}") from e

    if not r.ok:
        raise RuntimeError(
            f"Graph POST {path} returned {r.status_code}: {r.text[:200]}"
        )
    return r.json()


# ---------------------------------------------------------------------------
# Claude session management (per chat_id → Claude session_id)
# ---------------------------------------------------------------------------

def load_sessions() -> dict:
    if SESSIONS_PATH.exists():
        with SESSIONS_PATH.open() as f:
            return json.load(f)
    return {}


def save_sessions(sessions: dict) -> None:
    SESSIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = SESSIONS_PATH.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(sessions, f, indent=2)
    tmp.rename(SESSIONS_PATH)


# ---------------------------------------------------------------------------
# Message cursor (prevents re-processing messages on restart)
# ---------------------------------------------------------------------------

def load_cursor() -> dict:
    if STATE_PATH.exists():
        with STATE_PATH.open() as f:
            return json.load(f)
    return {}


def save_cursor(cursor: dict) -> None:
    tmp = STATE_PATH.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(cursor, f, indent=2)
    tmp.rename(STATE_PATH)


# ---------------------------------------------------------------------------
# Polling: list chats, fetch new messages
# ---------------------------------------------------------------------------

def _list_chats(cfg: dict) -> list[dict]:
    """Return 1-on-1 chats for the monitored user (up to 50)."""
    try:
        data = graph_get(
            cfg,
            f"/users/{cfg['_user_id']}/chats",
            params={"$filter": "chatType eq 'oneOnOne'", "$top": "50"},
        )
        return data.get("value", [])
    except Exception as e:
        logging.error(f"Failed to list chats: {e}")
        return []


def _strip_html(text: str) -> str:
    """Remove HTML tags and decode HTML entities (Teams sends HTML bodies)."""
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).strip()


def _fetch_messages_since(
    cfg: dict,
    chat_id: str,
    last_seen_id: str,
) -> tuple[list[dict], str]:
    """Fetch recent messages in a chat newer than last_seen_id.

    Returns (new_messages_oldest_first, highest_message_id_seen).
    The highest_message_id_seen covers ALL messages fetched (including the
    bot's own) so the cursor always advances past already-processed content.

    Teams message IDs are 19-digit microsecond timestamps stored as strings;
    lexicographic comparison is equivalent to chronological ordering.
    """
    try:
        data = graph_get(
            cfg,
            f"/chats/{chat_id}/messages",
            params={"$top": "20", "$orderby": "createdDateTime desc"},
        )
    except Exception as e:
        logging.error(f"Failed to fetch messages for chat {chat_id[:16]}...: {e}")
        return [], last_seen_id

    items = data.get("value", [])
    new_messages: list[dict] = []
    max_seen = last_seen_id

    for item in items:
        msg_id = str(item.get("id", ""))
        if not msg_id:
            continue

        # Track the high-water mark regardless of sender / type
        if msg_id > max_seen:
            max_seen = msg_id

        # Skip already-seen messages (list is newest-first so we can break early)
        if last_seen_id and msg_id <= last_seen_id:
            break

        # Only dispatch plain user messages
        if item.get("messageType") != "message":
            continue

        body = item.get("body", {})
        content_type = body.get("contentType", "text")
        text = body.get("content", "") or ""
        if content_type == "html":
            text = _strip_html(text)
        else:
            text = text.strip()

        if not text:
            continue

        sender_info = (item.get("from") or {}).get("user") or {}
        sender_id = str(sender_info.get("id", ""))
        sender_name = sender_info.get("displayName", sender_id)

        # Skip the bot's own outgoing messages
        if sender_id == cfg["_user_id"]:
            continue

        new_messages.append({
            "chat_id": chat_id,
            "msg_id": msg_id,
            "sender_id": sender_id,
            "sender_name": sender_name,
            "text": text,
        })

    # Messages arrived newest-first; reverse to dispatch in chronological order
    new_messages.reverse()
    return new_messages, max_seen


def poll_new_messages(cfg: dict, cursor: dict) -> list[dict]:
    """Return new text messages from authorized senders across all 1-on-1 chats."""
    allowed = set(cfg.get("allowed_user_ids", []))
    chats = _list_chats(cfg)
    all_new: list[dict] = []
    cursor_changed = False

    for chat in chats:
        chat_id = chat.get("id", "")
        if not chat_id:
            continue

        last_seen = cursor.get(chat_id, "")
        msgs, max_seen = _fetch_messages_since(cfg, chat_id, last_seen)

        # Always advance the cursor, even if no dispatchable messages arrived
        if max_seen and max_seen > last_seen:
            cursor[chat_id] = max_seen
            cursor_changed = True

        for msg in msgs:
            if allowed and msg["sender_id"] not in allowed:
                logging.debug(
                    f"Ignoring message from unauthorized user {msg['sender_id']}"
                )
                continue
            all_new.append(msg)

    if cursor_changed:
        save_cursor(cursor)

    return all_new


# ---------------------------------------------------------------------------
# Sending replies
# ---------------------------------------------------------------------------

def send_message(cfg: dict, chat_id: str, text: str) -> bool:
    """Send a plain-text message to a Teams chat. Returns True on success."""
    try:
        graph_post(
            cfg,
            f"/chats/{chat_id}/messages",
            {"body": {"contentType": "text", "content": text}},
        )
        return True
    except Exception as e:
        logging.error(f"send_message failed for {chat_id[:16]}...: {e}")
        return False


def send_reply(cfg: dict, chat_id: str, text: str) -> None:
    """Send reply, chunking into ≤4000-char pieces if necessary."""
    chunks = chunk_reply(text)
    for i, chunk in enumerate(chunks):
        ok = send_message(cfg, chat_id, chunk)
        if not ok:
            logging.error(
                f"Failed to send chunk {i + 1}/{len(chunks)} to {chat_id[:16]}..."
            )
        if len(chunks) > 1 and i < len(chunks) - 1:
            time.sleep(0.5)


# ---------------------------------------------------------------------------
# Reply chunking (Teams practical limit: ~4000 chars per message)
# ---------------------------------------------------------------------------

_TEAMS_MAX_CHARS = 4000
_CHUNK_HEADER_MAX = 8  # "[10/10] "


def chunk_reply(text: str) -> list[str]:
    """Split a long reply into ≤4000-char chunks, labeled [1/N] if needed."""
    if len(text) <= _TEAMS_MAX_CHARS:
        return [text]

    chunk_size = _TEAMS_MAX_CHARS - _CHUNK_HEADER_MAX
    paragraphs = text.split("\n\n")
    chunks: list[str] = []
    current = ""

    for para in paragraphs:
        candidate = (current + "\n\n" + para).strip() if current else para
        if len(candidate) <= chunk_size:
            current = candidate
        else:
            if current:
                chunks.append(current)
            if len(para) > chunk_size:
                sentences = para.replace(". ", ".\n").split("\n")
                current = ""
                for sentence in sentences:
                    candidate = (current + " " + sentence).strip() if current else sentence
                    if len(candidate) <= chunk_size:
                        current = candidate
                    else:
                        if current:
                            chunks.append(current)
                            current = ""
                        while len(sentence) > chunk_size:
                            chunks.append(sentence[:chunk_size])
                            sentence = sentence[chunk_size:]
                        current = sentence
            else:
                current = para

    if current:
        chunks.append(current)

    if len(chunks) > 1:
        total = len(chunks)
        chunks = [f"[{i + 1}/{total}] {c}" for i, c in enumerate(chunks)]

    return chunks


# ---------------------------------------------------------------------------
# Claude integration
# ---------------------------------------------------------------------------

def run_claude_chat(
    prompt: str,
    session_id: "str | None",
    model: str,
    system_prompt: str,
) -> "tuple[str, str]":
    """Invoke claude -p for one chat turn. Returns (reply, new_session_id)."""
    cmd = [
        "claude", "-p",
        "--dangerously-skip-permissions",
        "--output-format", "json",
        "--model", model,
    ]
    if session_id:
        cmd += ["--resume", session_id]
    else:
        cmd += ["--system-prompt", system_prompt]
    cmd.append(prompt)

    try:
        env = {**os.environ, "CLAUDECODE": ""}
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300, env=env)
    except subprocess.TimeoutExpired:
        return ("(Request timed out after 5 minutes. Please try again.)", session_id or "")
    except FileNotFoundError:
        return ("(Error: claude CLI not found. Is it installed and in PATH?)", "")

    if result.returncode != 0:
        err = (result.stderr or result.stdout).strip()
        logging.error(f"claude CLI failed (exit {result.returncode}): {err[:300]}")
        return ("(Claude error — check agent logs for details.)", session_id or "")

    try:
        data = json.loads(result.stdout)
        reply = data.get("result", "").strip()
        new_session = data.get("session_id", "") or session_id or ""
        return (reply or "(No response from Claude.)", new_session)
    except json.JSONDecodeError:
        return (result.stdout.strip()[:500] or "(Empty response.)", session_id or "")


def queue_agent_loop_task(task_text: str, chat_id: str, cfg: dict) -> str:
    """Write a one-task markdown file and invoke agent-loop.sh synchronously."""
    task_dir = AGENT_DIR / "teams-tasks"
    task_dir.mkdir(parents=True, exist_ok=True)
    # Truncate chat_id in filename to avoid filesystem limits
    task_file = task_dir / f"task-{chat_id[:24]}-{int(time.time())}.md"
    task_file.write_text(f"## Teams Task\n- {task_text}\n")

    agent_loop = Path(__file__).parent / "agent-loop.sh"
    if not agent_loop.exists():
        return "(Error: agent-loop.sh not found next to teams-agent.py.)"

    timeout = cfg.get("task_timeout_seconds", 600)
    try:
        env = {**os.environ, "CLAUDECODE": ""}
        result = subprocess.run(
            [str(agent_loop), "--model", cfg.get("model", "opus"), str(task_file)],
            capture_output=True, text=True, timeout=timeout, env=env,
        )
        if result.returncode == 0:
            return "Task completed successfully."
        return f"Task failed: {(result.stderr or result.stdout).strip()[:300]}"
    except subprocess.TimeoutExpired:
        return f"Task timed out (exceeded {timeout}s limit)."


# ---------------------------------------------------------------------------
# Command handling
# ---------------------------------------------------------------------------

def handle_command(text: str, chat_id: str, sessions: dict, cfg: dict) -> None:
    parts = text.split(None, 1)
    cmd = parts[0].lower()
    args = parts[1].strip() if len(parts) > 1 else ""

    if cmd == "/reset":
        if chat_id in sessions:
            del sessions[chat_id]
            save_sessions(sessions)
        send_reply(cfg, chat_id, "Session reset. Starting fresh.")

    elif cmd == "/mode":
        if args in ("chat", "task"):
            cfg["mode"] = args
            send_reply(cfg, chat_id, f"Switched to {args} mode.")
        else:
            send_reply(cfg, chat_id, "Usage: /mode chat | /mode task")

    elif cmd == "/status":
        send_reply(
            cfg, chat_id,
            f"Active sessions: {len(sessions)}. "
            f"Mode: {cfg.get('mode', 'chat')}. "
            f"Model: {cfg.get('model', 'sonnet')}.",
        )

    elif cmd == "/help":
        send_reply(
            cfg, chat_id,
            "/reset — clear this conversation and start fresh\n"
            "/mode chat — direct conversation with Claude\n"
            "/mode task — execute via agent-loop.sh\n"
            "/status — show current mode and session count\n"
            "/help — show this message\n\n"
            "Anything else is forwarded to Claude.",
        )

    else:
        send_reply(cfg, chat_id, f"Unknown command: {cmd}. Try /help.")


# ---------------------------------------------------------------------------
# Message dispatch
# ---------------------------------------------------------------------------

def dispatch_message(msg: dict, sessions: dict, cfg: dict) -> None:
    chat_id = msg["chat_id"]
    text = msg["text"].strip()
    sender_name = msg["sender_name"]

    logging.info(f"Message from {sender_name} [{chat_id[:16]}...]: {text[:80]}")

    if text.startswith("/"):
        handle_command(text, chat_id, sessions, cfg)
        return

    if cfg.get("mode", "chat") == "task":
        send_reply(cfg, chat_id, f"Running task: {text[:100]}...")
        result = queue_agent_loop_task(text, chat_id, cfg)
        send_reply(cfg, chat_id, result)
    else:
        session_id = sessions.get(chat_id)
        system_prompt = cfg.get(
            "system_prompt",
            "You are a helpful assistant. Be concise — your replies are sent via Microsoft Teams.",
        )
        reply, new_session = run_claude_chat(
            text, session_id, cfg.get("model", "sonnet"), system_prompt
        )
        if new_session:
            sessions[chat_id] = new_session
            save_sessions(sessions)
        send_reply(cfg, chat_id, reply)


# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    cfg = load_config()
    poll_interval = cfg.get("poll_interval_seconds", 30)

    logging.info("teams-agent starting")
    logging.info(f"Mode: {cfg.get('mode', 'chat')} | Model: {cfg.get('model', 'sonnet')}")
    logging.info(
        f"Allowed user IDs: {cfg.get('allowed_user_ids') or 'ALL (no restriction!)'}"
    )
    logging.info(f"Monitoring user: {cfg['_user_id']}")
    logging.info(f"Poll interval: {poll_interval}s")

    AGENT_DIR.mkdir(exist_ok=True)
    sessions = load_sessions()
    cursor = load_cursor()

    # Verify token acquisition works before entering the loop
    try:
        get_access_token(cfg)
        logging.info("Microsoft Graph: authenticated successfully (client credentials)")
    except Exception as e:
        logging.error(f"Failed to acquire access token: {e}")
        sys.exit(1)

    # Verify the monitored user exists and log their display name
    try:
        user_data = graph_get(
            cfg,
            f"/users/{cfg['_user_id']}",
            params={"$select": "displayName,userPrincipalName"},
        )
        logging.info(
            f"Monitoring: {user_data.get('displayName', '?')} "
            f"<{user_data.get('userPrincipalName', '?')}>"
        )
    except Exception as e:
        logging.error(f"Failed to verify monitored user: {e}")
        sys.exit(1)

    logging.info(f"Polling for messages every {poll_interval}s...")

    while True:
        try:
            new_msgs = poll_new_messages(cfg, cursor)
            for msg in new_msgs:
                try:
                    dispatch_message(msg, sessions, cfg)
                except Exception as e:
                    logging.error(f"Error dispatching message: {e}", exc_info=True)

        except KeyboardInterrupt:
            logging.info("Shutting down.")
            break

        except Exception as e:
            logging.error(f"Polling error: {e}", exc_info=True)

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
