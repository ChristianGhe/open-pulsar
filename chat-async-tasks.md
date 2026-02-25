## Implement: Non-blocking Chat + Fire-and-forget Loop

- Read `telegram-agent.py` in full. Then make the following changes so the Telegram polling loop is never blocked by either a Claude chat call or an agent-loop task:

  1. **Make chat calls non-blocking.** In `dispatch_message`, the chat-mode path calls `run_claude_chat` synchronously, blocking the polling loop for up to 5 minutes. Move it to the executor the same way loop tasks are already handled: call `tg_send_typing` immediately (before submitting), then `executor.submit(run_claude_chat, ...)` and attach a done callback that reads `(reply, new_session)` from the future result, updates `sessions`, saves, and calls `tg_send`. Guard concurrent chat calls per `chat_id` the same way `_active_tasks` guards loop tasks — if a reply is already in flight for this chat, send "Still thinking, please wait." and return.

  2. **Persist `_active_tasks` to disk so loop-task guards survive restarts.** Currently `_active_tasks` is in-memory only. On restart the guard is gone, so a user whose task is still running can accidentally submit a duplicate. Write `_active_tasks` to `.agent-loop/telegram-active.json` on every mutation (same atomic-rename pattern used for sessions and state). On startup, load it and remove any entries whose task files no longer exist in `.agent-loop/telegram-tasks/` (those are stale from a prior crash).

  3. **Send a richer completion message for loop tasks.** Currently `_task_done_callback` sends only "Task completed successfully." or "Task failed: ...". Instead, after the loop exits successfully, read `.agent-loop/state.json` and extract the per-task results: count completed vs failed tasks and include the task file name. Send a message like: "Task done. 3/3 completed." or "Task done with errors. 2/3 completed, 1 failed." On timeout, send "Task timed out after Xs. It may still be running — check with /status."

  Do not change any other logic. Do not add new commands, modes, or config keys.
