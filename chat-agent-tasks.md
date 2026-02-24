## Research: Non-blocking Chat Agent / Agent Loop Separation

- Study `telegram-agent.py` in full, focusing on how `queue_agent_loop_task` calls `agent-loop.sh` via `subprocess.run()` (blocking), how the Telegram polling loop works, and what state is maintained per chat (sessions, mode). Do not write any code yet.

- Research approaches for running `agent-loop.sh` non-blocking from `telegram-agent.py`: background threads, asyncio with `asyncio.create_subprocess_exec`, a dedicated worker process with a queue, and any other viable patterns. Consider: multiple concurrent tasks from different chats, sending an acknowledgment immediately on submission and a follow-up message on completion, error handling, timeout enforcement, and avoiding state corruption. Do not write any code yet — produce a written comparison of approaches with trade-offs.

- Based on the research, write a concrete implementation plan for the preferred approach. The plan must cover: what changes to make in `telegram-agent.py`, how task submission works, how completion callbacks send the result back via Telegram, how concurrent tasks are managed, and how the timeout is enforced without blocking the polling loop. Write the plan to `.agent-loop/chat-agent-separation-plan.md`.
