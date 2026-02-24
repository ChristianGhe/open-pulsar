## Implement: Non-blocking Chat Agent / Agent Loop Separation

- Read `telegram-agent.py` in full to understand the current structure before making any changes.

- Implement the `ThreadPoolExecutor` approach in `telegram-agent.py`. Specific changes required:
  1. Add `import threading` and `from concurrent.futures import ThreadPoolExecutor` at the top
  2. Add a module-level `_sessions_lock = threading.Lock()` to protect the shared `sessions` dict
  3. Add a module-level `_active_tasks: dict[int, str] = {}` to track in-progress tasks per chat_id, and a `_active_tasks_lock = threading.Lock()` to protect it
  4. Refactor `queue_agent_loop_task` to run `agent-loop.sh` non-blocking: the function should submit the work to a `ThreadPoolExecutor`, send an immediate acknowledgment message to the user via Telegram ("Task received, working on it..."), and send the result back when the work completes — all without blocking the polling loop
  5. Wrap all reads and writes to `sessions` with `_sessions_lock`
  6. Wrap `/reset` command's session mutation with `_sessions_lock`
  7. In `main()`, create `ThreadPoolExecutor(max_workers=4)` and pass it down; shut it down cleanly on KeyboardInterrupt
  8. Update `/status` command to include active task count from `_active_tasks`
  Do not change any other logic. Do not add comments unless the logic is non-obvious.
