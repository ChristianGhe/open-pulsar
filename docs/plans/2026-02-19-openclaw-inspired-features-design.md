# OpenClaw-Inspired Features Design

Inspired by analysis of [openclaw/openclaw](https://github.com/openclaw/openclaw), six features that transfer well to our batch task runner. All implemented as incremental patches to `agent-loop.sh` (single-file, ~250-350 lines added).

## Feature 1: Boot/Bootstrap File

Load project-specific context into the system prompt before execution.

**Lookup order (first found wins):**
1. `<!-- boot: path/to/file.md -->` directive in the task file (before any `##` heading)
2. `.agent-loop/boot.md` in the target directory

**Behavior:**
- Read file contents, append to `SYSTEM_PROMPT`
- Show in banner: `boot: .agent-loop/boot.md`

**Example `.agent-loop/boot.md`:**
```markdown
This is a Go project using Chi router and sqlc for database access.
Run tests with: go test ./...
The API follows RESTful conventions with JSON request/response bodies.
```

## Feature 2: Error Pre-Classification

Fast local pattern matching before calling Haiku for failure analysis. Saves time and API cost.

**New function `classify_error()`** returns one of:

| Classification | Patterns | Action |
|---|---|---|
| `rate_limit` | `429`, `rate_limit`, `Too Many Requests` | Retry after backoff, skip Haiku |
| `context_overflow` | `context_length`, `token limit`, `maximum context` | Fresh session, no retry of same approach |
| `auth` | `401`, `authentication`, `invalid.*key` | Fail immediately, no retry |
| `timeout` | `timeout`, `SIGTERM`, `timed out` | Retry once, skip Haiku |
| `network` | `ECONNREFUSED`, `DNS`, `network` | Retry after backoff, skip Haiku |
| `unknown` | everything else | Fall through to Haiku analysis (current behavior) |

Only `unknown` errors invoke `analyze_failure`.

## Feature 3: Exponential Backoff with Jitter

**New function `backoff_sleep(attempt, is_rate_limit)`:**
- Formula: `sleep_seconds = min(2^attempt + random(0..3), 60)`
  - Attempt 1: 2-5s, Attempt 2: 4-7s, Attempt 3: 8-11s, Attempt 4: 16-19s
  - Capped at 60s
- For `rate_limit` errors: double the base delay
- Print: `  waiting 8s before retry...`

Called in the retry loop before each re-attempt.

## Feature 4: Model Failover

**New CLI flag:** `--fallback-model <model>` (optional, no default)

**Triggers:** `rate_limit` or `timeout` classifications only (auth and context errors aren't model-specific).

**Behavior:**
- Swap `MODEL` and `FALLBACK_MODEL` on failover
- Log: `  failover: switching from opus to sonnet`
- If fallback also fails, swap back for next attempt
- Reset to user's original model choice after each task (success or final failure)
- No-op if `--fallback-model` not provided

**Usage:**
```bash
./agent-loop.sh --model opus --fallback-model sonnet tasks.md
```

## Feature 5: Context Compaction

Detect when a session's context window is filling up and start a fresh session with a summary.

**Token tracking:**
- After each `run_claude`, extract from JSON output:
  - Token counts from `usage` (input + cache_creation + cache_read + output)
  - `contextWindow` from `modelUsage.<model>`
- Track cumulative input tokens per session (`SESSION_TOKENS`, reset on new session)

**Trigger:** Cumulative usage exceeds 80% of `contextWindow`.

**Compaction process:**
1. Call Claude with `--resume` on current session: "Summarize the work completed so far — files created/modified, key decisions, current state. Be specific about file paths and function names."
2. Inject summary as preamble to next task's prompt:
   ```
   CONTEXT FROM PREVIOUS SESSION:
   <summary>

   NEXT TASK: <actual task text>
   ```
3. Reset `session_id` (fresh session) and `SESSION_TOKENS=0`
4. Log: `  compaction: context at 82%, starting fresh session with summary`

## Feature 6: Graceful Interrupt with Resume Context

Capture partial progress on Ctrl+C so resume attempts have context.

**New task state fields:**
- `interrupted_at`: ISO timestamp
- `partial_context`: last ~500 chars of output captured so far

**On interrupt:**
1. Read tail of current log file (last 500 chars)
2. Save as `partial_context` in task state
3. Set task status to `interrupted` (new status)
4. Abandon jj change, save state, exit

**On resume (encountering `interrupted` task):**
- Treat as fresh attempt (not skipped like `completed`, not abandoned like `failed`)
- Inject hint: `CONTEXT FROM INTERRUPTED ATTEMPT: <partial_context>`
- Fresh session (old session may be inconsistent)
- Reset attempt counter (interruption wasn't a failure)

## Implementation Approach

Incremental patches to `agent-loop.sh`, single file. Estimated ~250-350 lines added (~650 -> ~1000). Features are independent and can be implemented/tested in any order, though the suggested sequence is:

1. Boot file (no dependencies)
2. Exponential backoff (no dependencies)
3. Error pre-classification (backoff used by retry actions)
4. Model failover (uses classification to decide when to trigger)
5. Graceful interrupt (touches trap handler and state schema)
6. Context compaction (most complex, touches run_claude and execute_tasks)
