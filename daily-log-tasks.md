## Daily Logs

- Study agent-loop.sh in full, focusing on how tasks are executed, how state.json is updated, how per-task logs are written to .agent-loop/logs/, and what information is available at each stage (task name, group, status, duration, result, cost). Do not write any code yet.

- Add a daily logging feature to agent-loop.sh. At the start of each task execution and on completion, append a human-readable entry to .agent-loop/logs/agent_DDMMYYYY.log (where the date is the current local date). A new file is created automatically when the date rolls over at midnight. Each log entry should include: timestamp, task group, task name, status (started/completed/failed/retried), and on completion the result summary extracted from the Claude JSON output. The feature should be self-contained in a write_daily_log function and integrated cleanly into execute_tasks without disrupting existing logic.
