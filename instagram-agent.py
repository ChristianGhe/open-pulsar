#!/usr/bin/env python3
"""
instagram-agent.py — Remote communication with Claude via Instagram DMs.

Polls Instagram direct messages and forwards them to Claude (claude -p).
Replies with Claude's response. No backend or web server required.

Usage:
    python instagram-agent.py

Config: .agent-loop/instagram.json
Docs:   See README.md, "Instagram DM Integration" section.

NOTE: Uses Instagram's private web API via direct HTTP requests.
This is unofficial and violates Instagram's Terms of Service. Use at your own risk.
"""

import json
import logging
import os
import subprocess
import sys
import time
import urllib.parse
import uuid
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    print(
        "Error: python-dotenv not installed. Run: pip install -r requirements.txt",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    import requests
except ImportError:
    print(
        "Error: requests not installed. Run: pip install -r requirements.txt",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

AGENT_DIR = Path(".agent-loop")
CONFIG_PATH = AGENT_DIR / "instagram.json"
SESSIONS_PATH = AGENT_DIR / "instagram-sessions.json"
STATE_PATH = AGENT_DIR / "instagram-state.json"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


def load_config() -> dict:
    """Load config from .agent-loop/instagram.json.

    Credentials are never stored in the file; they come from env vars.
    """
    if not CONFIG_PATH.exists():
        print(
            f"Error: {CONFIG_PATH} not found.\n"
            "Create it by copying the example:\n"
            "  cp .agent-loop/instagram.json.example .agent-loop/instagram.json\n"
            "Then edit allowed_senders with your Instagram username.",
            file=sys.stderr,
        )
        sys.exit(1)

    with CONFIG_PATH.open() as f:
        cfg = json.load(f)

    username_env = cfg.get("username_env", "IG_USERNAME")
    password_env = cfg.get("password_env", "IG_PASSWORD")
    session_id_env = cfg.get("session_id_env", "IG_SESSION_ID")

    cfg["_username"] = os.environ.get(username_env, "")
    cfg["_password"] = os.environ.get(password_env, "")
    cfg["_session_id"] = urllib.parse.unquote(os.environ.get(session_id_env, ""))

    if not cfg["_username"]:
        print(f"Error: Set ${username_env} environment variable.", file=sys.stderr)
        sys.exit(1)

    if not cfg["_session_id"]:
        print(
            f"Error: Set ${session_id_env} to your Instagram sessionid cookie value.\n"
            "Get it from: Instagram.com → DevTools → Application → Cookies → sessionid",
            file=sys.stderr,
        )
        sys.exit(1)

    allowed = cfg.get("allowed_senders", [])
    if not allowed:
        logging.warning(
            "SECURITY WARNING: allowed_senders is empty — any Instagram user can "
            "trigger Claude. Set allowed_senders in .agent-loop/instagram.json."
        )

    return cfg


# ---------------------------------------------------------------------------
# Claude session management
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
# Message cursor (prevents re-processing on restart)
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
# Instagram HTTP client
# ---------------------------------------------------------------------------

_IG_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    ),
    "X-IG-App-ID": "936619743392459",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
}

_ig_session: requests.Session | None = None


def get_http_session(session_id: str) -> requests.Session:
    """Return (creating if needed) a requests.Session with Instagram cookies."""
    global _ig_session
    if _ig_session is None:
        _ig_session = requests.Session()
        _ig_session.headers.update(_IG_HEADERS)
        _ig_session.cookies.set("sessionid", session_id, domain=".instagram.com")
        # Prime the CSRF token with a lightweight GET
        try:
            r = _ig_session.get(
                "https://www.instagram.com/api/v1/accounts/current_user/?edit=true",
                timeout=15,
            )
            if r.status_code == 200:
                logging.info(
                    f"Instagram: authenticated as @{r.json().get('user', {}).get('username', '?')}"
                )
            else:
                logging.warning(f"Instagram: auth check returned {r.status_code}")
        except Exception as e:
            logging.warning(f"Instagram: auth check failed ({e})")
    return _ig_session


def reset_http_session() -> None:
    global _ig_session
    _ig_session = None


def _csrf() -> str:
    """Return current CSRF token from the session cookie jar."""
    if _ig_session is None:
        return ""
    return _ig_session.cookies.get("csrftoken", default="") or ""


# ---------------------------------------------------------------------------
# Polling
# ---------------------------------------------------------------------------


def poll_new_messages(cfg: dict, cursor: dict) -> list[dict]:
    """Return new text messages from authorized senders since last poll."""
    s = get_http_session(cfg["_session_id"])
    allowed = set(cfg.get("allowed_senders", []))
    new_messages = []

    try:
        r = s.get(
            "https://www.instagram.com/api/v1/direct_v2/inbox/",
            params={"visual_message_return_type": "unseen", "limit": "20"},
            timeout=20,
        )
        r.raise_for_status()
        threads = r.json().get("inbox", {}).get("threads", [])
    except Exception as e:
        logging.error(f"Failed to fetch inbox: {e}")
        return []

    for thread in threads:
        thread_id = str(thread["thread_id"])
        last_seen = cursor.get(thread_id, "")
        thread_new = []

        for item in thread.get("items", []):
            item_id = str(item["item_id"])

            if last_seen and item_id <= last_seen:
                continue
            if item.get("item_type") != "text":
                continue

            sender_pk = str(item.get("user_id", ""))
            sender_username = None
            for user in thread.get("users", []):
                if str(user.get("pk", "")) == sender_pk:
                    sender_username = user.get("username")
                    break

            if allowed and sender_username not in allowed:
                logging.debug(f"Ignoring message from @{sender_username}")
                continue

            thread_new.append(
                {
                    "thread_id": thread_id,
                    "sender_username": sender_username,
                    "text": item.get("text", ""),
                    "item_id": item_id,
                }
            )

            if item_id > cursor.get(thread_id, ""):
                cursor[thread_id] = item_id

        new_messages.extend(reversed(thread_new))  # oldest first

    if new_messages:
        save_cursor(cursor)

    return new_messages


def send_dm(cfg: dict, thread_id: str, text: str) -> bool:
    """Send a text DM to a thread. Returns True on success."""
    s = get_http_session(cfg["_session_id"])
    csrf = _csrf()

    try:
        r = s.post(
            "https://www.instagram.com/api/v1/direct_v2/threads/broadcast/text/",
            headers={"X-CSRFToken": csrf},
            data={
                "thread_ids": f'["{thread_id}"]',
                "text": text,
                "client_context": uuid.uuid4().hex,
            },
            timeout=20,
        )
        if r.status_code == 200 and r.headers.get("content-type", "").startswith("application/json"):
            logging.debug(f"Sent DM to {thread_id[:12]}...")
            return True
        # Instagram sometimes returns HTML on session issues
        logging.warning(
            f"send_dm unexpected response: status={r.status_code} "
            f"content-type={r.headers.get('content-type', '')} "
            f"body={r.text[:100]}"
        )
        return False
    except Exception as e:
        logging.error(f"send_dm failed: {e}")
        return False


# ---------------------------------------------------------------------------
# Claude integration
# ---------------------------------------------------------------------------


def run_claude_chat(
    prompt: str,
    session_id: str | None,
    model: str,
    system_prompt: str,
) -> tuple[str, str]:
    """Invoke claude -p for one chat turn.

    Mirrors the pattern in agent-loop.sh run_claude() (lines 439-494):
      claude -p --dangerously-skip-permissions --output-format json
              --model M [--resume S | --system-prompt P] "prompt"

    Returns (reply_text, new_session_id).
    """
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
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
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


def queue_agent_loop_task(task_text: str, thread_id: str, cfg: dict) -> str:
    """Write a one-task markdown file and invoke agent-loop.sh synchronously."""
    task_dir = AGENT_DIR / "instagram-tasks"
    task_dir.mkdir(parents=True, exist_ok=True)
    task_file = task_dir / f"task-{thread_id}-{int(time.time())}.md"
    task_file.write_text(f"## Instagram Task\n- {task_text.replace(chr(10) + '- ', chr(10) + '  ')}\n")

    agent_loop = Path(__file__).parent / "agent-loop.sh"
    if not agent_loop.exists():
        return "(Error: agent-loop.sh not found next to instagram-agent.py.)"

    timeout = cfg.get("task_timeout_seconds", 600)
    try:
        result = subprocess.run(
            [str(agent_loop), "--model", cfg.get("model", "opus"), str(task_file)],
            capture_output=True, text=True, timeout=timeout,
        )
        if result.returncode == 0:
            return "Task completed successfully."
        return f"Task failed: {(result.stderr or result.stdout).strip()[:300]}"
    except subprocess.TimeoutExpired:
        return f"Task timed out (exceeded {timeout}s limit)."


# ---------------------------------------------------------------------------
# Reply chunking (Instagram 1000-char limit)
# ---------------------------------------------------------------------------

_INSTAGRAM_MAX_CHARS = 1000
_CHUNK_HEADER_MAX = 8  # "[10/10] "


def chunk_reply(text: str) -> list[str]:
    """Split a long reply into ≤1000-char chunks, labeled [1/N], [2/N], etc."""
    if len(text) <= _INSTAGRAM_MAX_CHARS:
        return [text]

    chunk_size = _INSTAGRAM_MAX_CHARS - _CHUNK_HEADER_MAX
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
# Sending replies
# ---------------------------------------------------------------------------


def send_reply(cfg: dict, thread_id: str, text: str) -> None:
    """Send reply, chunking if necessary."""
    chunks = chunk_reply(text)
    for i, chunk in enumerate(chunks):
        ok = send_dm(cfg, thread_id, chunk)
        if not ok:
            logging.error(f"Failed to send chunk {i + 1}/{len(chunks)} to {thread_id[:12]}...")
        if len(chunks) > 1 and i < len(chunks) - 1:
            time.sleep(0.5)


# ---------------------------------------------------------------------------
# Command handling
# ---------------------------------------------------------------------------

_COMMAND_PREFIX = "/"


def handle_command(
    text: str, thread_id: str, sessions: dict, cfg: dict,
) -> None:
    parts = text.split(None, 1)
    cmd = parts[0].lower()
    args = parts[1].strip() if len(parts) > 1 else ""

    if cmd == "/reset":
        if thread_id in sessions:
            del sessions[thread_id]
            save_sessions(sessions)
        send_reply(cfg, thread_id, "Session reset. Starting fresh.")

    elif cmd == "/mode":
        if args in ("chat", "task"):
            cfg["mode"] = args
            send_reply(cfg, thread_id, f"Switched to {args} mode.")
        else:
            send_reply(cfg, thread_id, "Usage: /mode chat | /mode task")

    elif cmd == "/status":
        send_reply(cfg, thread_id,
            f"Active sessions: {len(sessions)}. "
            f"Mode: {cfg.get('mode', 'chat')}. "
            f"Model: {cfg.get('model', 'opus')}."
        )

    elif cmd == "/help":
        send_reply(cfg, thread_id,
            "/reset — clear this conversation and start fresh\n"
            "/mode chat — direct conversation with Claude\n"
            "/mode task — execute via agent-loop.sh\n"
            "/status — show current mode and session count\n"
            "/help — show this message\n\n"
            "Anything else is forwarded to Claude."
        )

    else:
        send_reply(cfg, thread_id, f"Unknown command: {cmd}. Try /help.")


# ---------------------------------------------------------------------------
# Message dispatch
# ---------------------------------------------------------------------------


def dispatch_message(msg: dict, sessions: dict, cfg: dict) -> None:
    thread_id = msg["thread_id"]
    text = msg["text"].strip()
    sender = msg["sender_username"]

    logging.info(f"Message from @{sender} [{thread_id[:12]}...]: {text[:80]}")

    if text.startswith(_COMMAND_PREFIX):
        handle_command(text, thread_id, sessions, cfg)
        return

    if cfg.get("mode", "chat") == "task":
        send_reply(cfg, thread_id, f"Running task: {text[:100]}...")
        result = queue_agent_loop_task(text, thread_id, cfg)
        send_reply(cfg, thread_id, result)
    else:
        session_id = sessions.get(thread_id)
        system_prompt = cfg.get(
            "system_prompt",
            "You are a helpful assistant. Be concise — your replies are sent via Instagram DM.",
        )
        reply, new_session = run_claude_chat(
            text, session_id, cfg.get("model", "sonnet"), system_prompt
        )
        if new_session:
            sessions[thread_id] = new_session
            save_sessions(sessions)
        send_reply(cfg, thread_id, reply)


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

    logging.info("instagram-agent starting")
    logging.info(f"Mode: {cfg.get('mode', 'chat')} | Model: {cfg.get('model', 'sonnet')}")
    logging.info(f"Allowed senders: {cfg.get('allowed_senders', [])}")
    logging.info(f"Poll interval: {poll_interval}s")

    AGENT_DIR.mkdir(exist_ok=True)
    sessions = load_sessions()
    cursor = load_cursor()

    # Initialize HTTP session (validates credentials)
    get_http_session(cfg["_session_id"])

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
            # Reset HTTP session on errors so it re-initializes on next cycle
            reset_http_session()

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
