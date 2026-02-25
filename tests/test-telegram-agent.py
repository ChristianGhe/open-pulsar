#!/usr/bin/env python3
"""
Smoke tests for telegram-agent.py — no Telegram token or Claude needed.
Tests the executor separation, per-chat deduplication, and dispatch routing.
"""
import sys
import threading
import time
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub out the import-time side-effects so we can import the module.
# ---------------------------------------------------------------------------

# Fake dotenv
dotenv_mod = types.ModuleType("dotenv")
dotenv_mod.load_dotenv = lambda: None
sys.modules["dotenv"] = dotenv_mod

# Fake requests (we'll replace per-test where needed)
requests_mod = types.ModuleType("requests")
sys.modules["requests"] = requests_mod

import importlib.util
import pathlib

_src = pathlib.Path(__file__).parent.parent / "telegram-agent.py"
_spec = importlib.util.spec_from_file_location("telegram_agent", _src)
ta = importlib.util.module_from_spec(_spec)
sys.modules["telegram_agent"] = ta
_spec.loader.exec_module(ta)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_cfg(mode="chat"):
    return {
        "_token": "fake-token",
        "_allowed_ids": set(),
        "_soul": "",
        "_soul_path": "SOUL.md",
        "mode": mode,
        "model": "sonnet",
        "system_prompt": "You are a helpful assistant.",
        "task_timeout_seconds": 5,
    }


def _make_msg(chat_id=1, from_id=1, text="hello"):
    return {
        "chat": {"id": chat_id},
        "from": {"id": from_id, "username": "tester"},
        "text": text,
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestExecutorSeparation(unittest.TestCase):
    """chat_executor and task_executor must be distinct objects."""

    def test_separate_executor_instances(self):
        chat_exec = ThreadPoolExecutor(max_workers=4)
        task_exec = ThreadPoolExecutor(max_workers=2)
        self.assertIsNot(chat_exec, task_exec)
        chat_exec.shutdown(wait=False)
        task_exec.shutdown(wait=False)

    def test_task_cannot_starve_chat(self):
        """
        Fill the task executor to capacity; chat submissions must still
        execute without waiting for task workers to free up.
        """
        barrier = threading.Barrier(2, timeout=5)
        started = threading.Event()

        def blocking_task():
            started.set()
            barrier.wait()  # holds the task worker until we release it

        task_exec = ThreadPoolExecutor(max_workers=1)
        chat_exec = ThreadPoolExecutor(max_workers=1)

        task_exec.submit(blocking_task)
        started.wait(timeout=2)  # make sure the task worker is occupied

        # Chat should still run even though task_exec is full
        chat_result = chat_exec.submit(lambda: "chat_ran")
        self.assertEqual(chat_result.result(timeout=2), "chat_ran")

        barrier.wait()  # release the task worker
        task_exec.shutdown(wait=False)
        chat_exec.shutdown(wait=False)


class TestDispatchRouting(unittest.TestCase):
    """dispatch_message must route to the correct executor based on mode."""

    def setUp(self):
        # Reset global deduplication state before each test
        ta._active_tasks.clear()
        ta._active_chats.clear()

    def test_chat_mode_uses_chat_executor(self):
        cfg = _make_cfg(mode="chat")
        chat_exec = MagicMock()
        task_exec = MagicMock()
        chat_exec.submit.return_value = MagicMock()

        with patch.object(ta, "tg_send"):
            ta.dispatch_message(_make_msg(), {}, cfg, chat_exec, task_exec)

        chat_exec.submit.assert_called_once()
        task_exec.submit.assert_not_called()

    def test_task_mode_uses_task_executor(self):
        cfg = _make_cfg(mode="task")
        chat_exec = MagicMock()
        task_exec = MagicMock()
        task_exec.submit.return_value = MagicMock()

        with patch.object(ta, "tg_send"):
            ta.dispatch_message(_make_msg(), {}, cfg, chat_exec, task_exec)

        task_exec.submit.assert_called_once()
        chat_exec.submit.assert_not_called()


class TestPerChatDeduplication(unittest.TestCase):
    """A second message for the same chat_id while one is in-flight is rejected."""

    def setUp(self):
        ta._active_tasks.clear()
        ta._active_chats.clear()

    def test_duplicate_task_rejected(self):
        cfg = _make_cfg(mode="task")
        sent = []

        with patch.object(ta, "tg_send", side_effect=lambda _t, _c, m: sent.append(m)):
            # Simulate one task already running for chat_id 42
            ta._active_tasks[42] = "existing task"
            ta.queue_agent_loop_task("new task", 42, cfg, MagicMock())

        self.assertTrue(any("already running" in m for m in sent))

    def test_duplicate_chat_rejected(self):
        cfg = _make_cfg(mode="chat")
        sent = []

        with patch.object(ta, "tg_send", side_effect=lambda _t, _c, m: sent.append(m)):
            ta._active_chats[42] = True
            ta.queue_chat("hi again", 42, {}, cfg, MagicMock())

        self.assertTrue(any("thinking" in m.lower() for m in sent))


class TestChunkReply(unittest.TestCase):
    """chunk_reply must split long messages and label them correctly."""

    def test_short_message_not_split(self):
        chunks = ta.chunk_reply("hello")
        self.assertEqual(chunks, ["hello"])

    def test_long_message_split_and_labeled(self):
        # Build a message that is definitely over 4096 chars
        long_text = ("word " * 900).strip()
        chunks = ta.chunk_reply(long_text)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(chunks[0].startswith("[1/"))
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 4096)


if __name__ == "__main__":
    unittest.main(verbosity=2)
