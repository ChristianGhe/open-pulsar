#!/usr/bin/env python3
"""
telegram-agent.py — Remote communication with Claude via Telegram.

Polls Telegram messages and forwards them to Claude (claude -p).
Replies with Claude's response. No backend or webhooks required.

Setup:
    1. Message @BotFather on Telegram → /newbot → copy the token
    2. Message @userinfobot to get your numeric user ID
    3. Add to .env:
           telegram_token=123456789:AAF...
           telegram_allowed_ids=987654321
    4. cp .agent-loop/telegram.json.example .agent-loop/telegram.json
    5. python telegram-agent.py

Config: .agent-loop/telegram.json
"""

import json
import logging
import os
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


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

AGENT_DIR = Path(".agent-loop")
CONFIG_PATH = AGENT_DIR / "telegram.json"
SESSIONS_PATH = AGENT_DIR / "telegram-sessions.json"
STATE_PATH = AGENT_DIR / "telegram-state.json"


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(
            f"Error: {CONFIG_PATH} not found.\n"
            "  cp .agent-loop/telegram.json.example .agent-loop/telegram.json",
            file=sys.stderr,
        )
        sys.exit(1)

    with CONFIG_PATH.open() as f:
        cfg = json.load(f)

    token_env = cfg.get("token_env", "telegram_token")
    allowed_env = cfg.get("allowed_ids_env", "telegram_allowed_ids")

    cfg["_token"] = os.environ.get(token_env, "")
    raw_ids = os.environ.get(allowed_env, "")
    cfg["_allowed_ids"] = {int(x.strip()) for x in raw_ids.split(",") if x.strip()}

    if not cfg["_token"]:
        print(f"Error: Set ${token_env} in your .env file.\n"
              "Get a token from @BotFather on Telegram.", file=sys.stderr)
        sys.exit(1)

    if not cfg["_allowed_ids"]:
        logging.warning(
            "SECURITY WARNING: telegram_allowed_ids is empty — "
            "anyone can trigger Claude. Set it to your Telegram user ID."
        )

    return cfg


# ---------------------------------------------------------------------------
# Offset persistence (prevents reprocessing messages on restart)
# ---------------------------------------------------------------------------

def load_offset() -> int:
    if STATE_PATH.exists():
        with STATE_PATH.open() as f:
            return json.load(f).get("offset", 0)
    return 0


def save_offset(offset: int) -> None:
    tmp = STATE_PATH.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump({"offset": offset}, f)
    tmp.rename(STATE_PATH)


# ---------------------------------------------------------------------------
# Claude session management (per chat_id)
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
# Telegram API
# ---------------------------------------------------------------------------

def _base(token: str) -> str:
    return f"https://api.telegram.org/bot{token}"


def tg_get_updates(token: str, offset: int, timeout: int = 30) -> list[dict]:
    """Long-poll for new updates. Blocks up to `timeout` seconds."""
    try:
        r = requests.get(
            f"{_base(token)}/getUpdates",
            params={"offset": offset, "timeout": timeout},
            timeout=timeout + 10,
        )
        r.raise_for_status()
        return r.json().get("result", [])
    except Exception as e:
        logging.error(f"getUpdates failed: {e}")
        return []


def tg_send(token: str, chat_id: int, text: str) -> None:
    """Send a message, splitting into chunks if it exceeds 4096 chars."""
    for chunk in chunk_reply(text):
        try:
            r = requests.post(
                f"{_base(token)}/sendMessage",
                json={"chat_id": chat_id, "text": chunk},
                timeout=15,
            )
            if not r.ok:
                logging.warning(f"sendMessage returned {r.status_code}: {r.text[:100]}")
        except Exception as e:
            logging.error(f"sendMessage failed: {e}")


def tg_send_typing(token: str, chat_id: int) -> None:
    """Show 'typing...' indicator while Claude is thinking."""
    try:
        requests.post(
            f"{_base(token)}/sendChatAction",
            json={"chat_id": chat_id, "action": "typing"},
            timeout=5,
        )
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Reply chunking (Telegram 4096-char limit)
# ---------------------------------------------------------------------------

_TG_MAX_CHARS = 4096
_CHUNK_HEADER_MAX = 8  # "[10/10] "


def chunk_reply(text: str) -> list[str]:
    """Split a long reply into ≤4096-char chunks, labeled [1/N] if needed."""
    if len(text) <= _TG_MAX_CHARS:
        return [text]

    chunk_size = _TG_MAX_CHARS - _CHUNK_HEADER_MAX
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
    session_id: str | None,
    model: str,
    system_prompt: str,
) -> tuple[str, str]:
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


def queue_agent_loop_task(task_text: str, chat_id: int, cfg: dict) -> str:
    """Write a one-task markdown file and invoke agent-loop.sh synchronously."""
    task_dir = AGENT_DIR / "telegram-tasks"
    task_dir.mkdir(parents=True, exist_ok=True)
    task_file = task_dir / f"task-{chat_id}-{int(time.time())}.md"
    task_file.write_text(f"## Telegram Task\n- {task_text}\n")

    agent_loop = Path(__file__).parent / "agent-loop.sh"
    if not agent_loop.exists():
        return "(Error: agent-loop.sh not found next to telegram-agent.py.)"

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

def handle_command(text: str, chat_id: int, sessions: dict, cfg: dict) -> None:
    token = cfg["_token"]
    parts = text.split(None, 1)
    cmd = parts[0].lower().split("@")[0]  # strip @botname suffix if present
    args = parts[1].strip() if len(parts) > 1 else ""

    if cmd == "/reset":
        key = str(chat_id)
        if key in sessions:
            del sessions[key]
            save_sessions(sessions)
        tg_send(token, chat_id, "Session reset. Starting fresh.")

    elif cmd == "/mode":
        if args in ("chat", "task"):
            cfg["mode"] = args
            tg_send(token, chat_id, f"Switched to {args} mode.")
        else:
            tg_send(token, chat_id, "Usage: /mode chat | /mode task")

    elif cmd == "/status":
        tg_send(token, chat_id,
            f"Active sessions: {len(sessions)}\n"
            f"Mode: {cfg.get('mode', 'chat')}\n"
            f"Model: {cfg.get('model', 'sonnet')}"
        )

    elif cmd == "/help":
        tg_send(token, chat_id,
            "/reset — clear this conversation and start fresh\n"
            "/mode chat — direct conversation with Claude\n"
            "/mode task — execute via agent-loop.sh\n"
            "/status — show current mode and session count\n"
            "/help — show this message\n\n"
            "Anything else is forwarded to Claude."
        )

    else:
        tg_send(token, chat_id, f"Unknown command: {cmd}. Try /help.")


# ---------------------------------------------------------------------------
# Message dispatch
# ---------------------------------------------------------------------------

def dispatch_message(msg: dict, sessions: dict, cfg: dict) -> None:
    token = cfg["_token"]
    chat_id: int = msg["chat"]["id"]
    from_id: int = msg.get("from", {}).get("id", 0)
    text: str = (msg.get("text") or "").strip()
    username: str = msg.get("from", {}).get("username", str(from_id))

    if not text:
        return  # ignore non-text messages (photos, stickers, etc.)

    # Authorization check
    allowed = cfg["_allowed_ids"]
    if allowed and from_id not in allowed:
        logging.debug(f"Ignoring message from unauthorized user {from_id} (@{username})")
        return

    logging.info(f"Message from @{username} [{from_id}]: {text[:80]}")

    if text.startswith("/"):
        handle_command(text, chat_id, sessions, cfg)
        return

    if cfg.get("mode", "chat") == "task":
        tg_send(token, chat_id, f"Running task: {text[:100]}...")
        result = queue_agent_loop_task(text, chat_id, cfg)
        tg_send(token, chat_id, result)
    else:
        tg_send_typing(token, chat_id)
        key = str(chat_id)
        session_id = sessions.get(key)
        system_prompt = cfg.get(
            "system_prompt",
            "You are a helpful assistant.",
        )
        reply, new_session = run_claude_chat(
            text, session_id, cfg.get("model", "sonnet"), system_prompt
        )
        if new_session:
            sessions[key] = new_session
            save_sessions(sessions)
        tg_send(token, chat_id, reply)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    cfg = load_config()
    token = cfg["_token"]

    logging.info("telegram-agent starting")
    logging.info(f"Mode: {cfg.get('mode', 'chat')} | Model: {cfg.get('model', 'sonnet')}")
    logging.info(f"Allowed user IDs: {cfg['_allowed_ids'] or 'ALL (no restriction!)'}")

    AGENT_DIR.mkdir(exist_ok=True)
    sessions = load_sessions()
    offset = load_offset()

    # Verify token with a lightweight API call
    try:
        r = requests.get(f"{_base(token)}/getMe", timeout=10)
        r.raise_for_status()
        bot = r.json()["result"]
        logging.info(f"Connected as @{bot['username']} (id={bot['id']})")
    except Exception as e:
        logging.error(f"Failed to connect to Telegram: {e}")
        sys.exit(1)

    logging.info("Polling for messages (long-poll, timeout=30s)...")

    while True:
        try:
            updates = tg_get_updates(token, offset, timeout=30)
            for update in updates:
                offset = update["update_id"] + 1
                save_offset(offset)
                msg = update.get("message") or update.get("edited_message")
                if msg:
                    try:
                        dispatch_message(msg, sessions, cfg)
                    except Exception as e:
                        logging.error(f"Error dispatching message: {e}", exc_info=True)

        except KeyboardInterrupt:
            logging.info("Shutting down.")
            break
        except Exception as e:
            logging.error(f"Polling error: {e}", exc_info=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
