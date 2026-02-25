# Code Review: agent-loop.sh

Reviewed against commit as of 2026-02-25. All line numbers refer to the current `agent-loop.sh`.

---

## 1. Bugs & Edge Cases

### 1.1 `parse_tasks` — CRLF line endings corrupt group names and task text

**Lines 180–208**

The parser uses `while IFS= read -r line` with no CRLF stripping. If the task file was authored on Windows, every line ends with `\r`. The heading regex captures the trailing `\r` into the group name:

```bash
if [[ "$line" =~ ^##[[:space:]]+(.+)$ ]]; then
    current_group="${BASH_REMATCH[1]}"  # e.g. "Backend API\r"
```

`\r` is classified as `[[:space:]]` by POSIX, so the pattern _matches_ but the captured group includes the carriage return. The same applies to task text. Downstream effects:

- `slugify` replaces `\r` with `-`, generating log names like `001-backend-api--create-a-rest-api-.log`.
- The daily log, banner, and `show_status` output contain invisible `\r` characters.
- The jq `--arg` value for `"task"` stores the `\r`, causing `jq -r` to emit garbled text.

**Fix:** Strip `\r` on each line: `line="${line%$'\r'}"` at the top of the while body.

---

### 1.2 `parse_tasks` — `###` and `#` headings silently ignored, treated as task content

**Lines 182–186**

```bash
if [[ "$line" =~ ^##[[:space:]]+(.+)$ ]]; then
```

Only `##` headings are group delimiters. A `### Sub-section` line:

- Does **not** match the group-heading branch (because `##` is followed by `#`, not whitespace).
- Does **not** match the task branch (doesn't start with `-`).
- If `in_multiline=true`, it matches the continuation branch and is appended to the current task text.
- If `in_multiline=false`, it falls through all branches and is silently discarded.

A user who writes `# Title` or `### Step` as a top-level section will get either corrupted task text or silently lost structure with no warning.

---

### 1.3 `parse_tasks` — `flush_task` no-ops when `current_task` is empty but leaves `in_multiline=true`

**Lines 158–168, 196–205**

```bash
flush_task() {
    if [[ -n "$current_task" ]]; then   # <-- guard
        ...
        in_multiline=false
    fi
    # If current_task is empty, in_multiline is NOT reset
}
```

If two consecutive `##` headings appear without any intervening task:

```markdown
## Group A
## Group B
- Task one
```

At the second `##`, `flush_task` is called with `current_task=""`. The guard means `in_multiline` is **not** reset. In this specific case `in_multiline` is already `false`, so there is no immediate bug. However if a task line is followed immediately by another `##` without a blank line and `flush_task`'s guard fails for any reason, `in_multiline` can remain `true` when it should be `false`. This also makes `flush_task` semantically incomplete: a flush that does nothing should still reset the multiline flag.

---

### 1.4 `run_claude` — `exit_code` variable shadowed by `set -e` in subshell

**Lines 474–475**

```bash
local exit_code=0
output=$(cd "$TARGET_DIR" && CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>&1) || exit_code=$?
```

`set -euo pipefail` is active. Command substitution (`$(...)`) runs in a subshell. If claude exits non-zero inside the substitution, the substitution itself returns a non-empty string (stderr/stdout mixed) **and** returns a non-zero exit code. The `|| exit_code=$?` correctly captures it. However, because `set -e` applies to the _outer_ shell, if the command after `||` (`exit_code=$?`) were to fail, the script would exit without reaching the `if [[ $exit_code -ne 0 ]]` check. In practice `exit_code=$?` can't fail, but the pattern is subtly load-bearing.

More practically: `2>&1` merges stderr into stdout. When Claude exits 0 but emits startup warnings to stderr, those warnings are prepended to the JSON output in `$output`. Then:

```bash
new_session_id=$(echo "$output" | jq -r '.session_id // empty' 2>/dev/null || echo "")
```

jq fails to parse (non-JSON prefix), silently returns `""`, and `session_id` becomes empty. The next task therefore loses session continuity **with no error message**.

---

### 1.5 `run_claude` — colon-delimited return value breaks when session ID contains colons

**Lines 492–493, 670–672**

```bash
# run_claude return:
echo "${new_session_id}:${token_info}"      # → "SESSION:TOKENS:WINDOW"

# execute_tasks parsing:
new_session_id=$(echo "$claude_output" | cut -d: -f1)
new_tokens=$(echo "$claude_output" | cut -d: -f2)
new_window=$(echo "$claude_output" | cut -d: -f3)
```

Claude session IDs are currently UUID-like strings without colons, so this works today. But the protocol is undocumented and the format could change. If a session ID ever contains `:` (e.g., a versioned or namespaced identifier like `proj:abc123`):

- `cut -d: -f1` returns only `proj`, not the full ID.
- `cut -d: -f2` returns `abc123`, interpreted as the token count, causing `SESSION_TOKENS=$((SESSION_TOKENS + abc123))` to fail arithmetic.
- `cut -d: -f3` returns the actual token count, stored as `CONTEXT_WINDOW`.

All three values would be silently wrong with no error.

---

### 1.6 `run_claude` — empty `new_session_id` returns a colon-prefixed string that passes the `-n` guard

**Lines 487–492, 668**

If jq successfully parses the Claude output but `.session_id` is absent (e.g., an unexpected JSON shape), `new_session_id` is `""`. Then:

```bash
echo "${new_session_id}:${token_info}"   # → ":3800:200000"
```

Back in `execute_tasks`:

```bash
if [[ $run_exit -eq 0 && -n "$claude_output" ]]; then
```

`-n ":3800:200000"` is **true** (non-empty string), so the success branch is taken. `session_id` is set to `""`, the task is marked completed, but the next task will start a fresh session rather than resuming — silently breaking session continuity.

---

### 1.7 `execute_tasks` — `SESSION_TOKENS` not persisted across script restarts

**Lines 15, 604–608, 675**

```bash
SESSION_TOKENS=0   # global initialisation
```

When a run is interrupted and resumed, `SESSION_TOKENS` starts at zero even if the inherited session has already consumed, say, 170,000 tokens. `compact_session` therefore never triggers (`0 / 200000 = 0%`). The real context may already be near the limit, and the next task may receive a context-length error rather than a proactive compaction.

The fix requires persisting accumulated session tokens in `state.json` per group (or per session) and restoring them on resume.

---

### 1.8 `execute_tasks` — `COMPACTION_SUMMARY` leaks across group boundaries

**Lines 604–608, 754–767**

When starting a new group, the script resets `session_id` and `SESSION_TOKENS` but does **not** clear `COMPACTION_SUMMARY`:

```bash
if [[ "$group" != "$current_group" ]]; then
    current_group="$group"
    session_id=""
    SESSION_TOKENS=0
    # COMPACTION_SUMMARY is NOT cleared here
fi
```

If compaction fires after the last task of Group A, `COMPACTION_SUMMARY` holds Group A's session summary. The first task of Group B then receives:

```
CONTEXT FROM PREVIOUS SESSION:
<Group A's summary>

NEXT TASK: <Group B's first task>
```

This injects irrelevant context into an unrelated group's session.

---

### 1.9 `execute_tasks` — orphaned jj change if interrupted between `jj_new_change` and `update_task_state`

**Lines 632–637**

```bash
jj_change=$(jj_new_change "agent-loop: $group / $task")
if [[ -n "$jj_change" ]]; then
    echo -e "  ${YELLOW}jj:${NC} created change $jj_change"
    update_task_state "$i" "jj_change" "$jj_change"   # <-- signal could arrive here
fi
```

If SIGINT arrives after `jj_new_change` returns but before `update_task_state` writes the change ID to `state.json`, `_handle_interrupt` reads the old `jj_change` value from state (likely `null` for a first attempt). `jj_abandon_change "null"` is a no-op (line 350), so the freshly created jj change is never abandoned — it becomes an orphan in the repository.

---

### 1.10 `_handle_interrupt` — orphaned `mktemp` file when interrupt fires mid-`update_task_state`

**Lines 297–301**

```bash
update_task_state() {
    ...
    local tmp
    tmp=$(mktemp)
    jq ... "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}
```

If SIGINT arrives during the `update_task_state` call that `_handle_interrupt` itself makes (e.g., the first `update_task_state` call at line 575), the signal is now blocked (`trap '' INT TERM` at line 559), so the handler won't re-enter. However, if the interrupt fires during a `update_task_state` call in `execute_tasks`, the interrupted `$tmp` file is left on disk. `_handle_interrupt` then calls its own `update_task_state` calls which create new temp files. The orphaned temp file from the interrupted call is never cleaned up.

---

### 1.11 `extract_token_usage` — `modelUsage` object ordering is not guaranteed

**Line 404**

```bash
context_window=$(jq -r '[.modelUsage[]] | .[0].contextWindow // 200000' "$json_file" 2>/dev/null || echo 200000)
```

`[.modelUsage[]]` converts the object's values into an array. JSON objects have no defined key order, so in a multi-model response, `.[0]` might not be the model whose context window is most relevant. In practice, Claude API responses have a single model entry, so this works today. But it is fragile if multiple models appear (e.g., tool-use routing, multi-model batches).

---

### 1.12 `analyze_failure` — hardcoded `haiku` model name

**Line 535**

```bash
result=$(CLAUDECODE= claude -p \
    --model haiku \
    ...
```

The string `"haiku"` is hardcoded regardless of `--model` and `--fallback-model`. This is a bug in at least three scenarios:

1. The user's API key does not have access to the Haiku model (enterprise tier restrictions).
2. The Claude CLI requires the full model name (`claude-haiku-3-5` or `claude-haiku-4`) rather than the alias; behaviour depends on CLI version.
3. Haiku is renamed or deprecated; the analysis call silently fails and returns the hard-coded `{"retry": false, ...}` fallback.

There is no configurable analysis model variable.

---

### 1.13 `show_status` — "pending" count is wrong when tasks are in "running" status

**Lines 135–139**

```bash
pending=$((total - completed - failed - interrupted))
```

If a task was marked "running" (line 639) and the process was killed with `SIGKILL` (bypassing the trap), the task remains in "running" status. The formula treats it as pending (it's not subtracted), **overstating** the pending count. The `show_status` table will display the task with symbol `...` (the catch-all), indistinguishable from a truly pending task.

---

### 1.14 `jj_new_change` — "unknown" change ID causes spurious `jj abandon` failure

**Lines 342–345, 348–352**

```bash
change_id=$(cd "$TARGET_DIR" && jj log -r @ --no-graph -T 'change_id.short()' 2>/dev/null || echo "unknown")
```

If `jj log` fails after `jj new` succeeds, `change_id` is the string `"unknown"`. `jj_abandon_change "unknown"` passes the guard (`-n "unknown"` and `"unknown" != "null"` both true) and attempts `jj abandon "unknown"`, which jj rejects. The `|| true` swallows the error, and the real jj change is orphaned.

---

### 1.15 `slugify` — group slug has no length cap

**Lines 225–227, 252–254**

```bash
group_slug=$(slugify "$group")               # no length limit
task_slug=$(slugify "$task" | cut -c1-50)    # capped at 50
log_name=$(printf "%03d-%s--%s.log" "$((i + 1))" "$group_slug" "$task_slug")
```

A verbose group name ("Everything related to the backend authentication and user management subsystem") produces a 70-character slug. With the `NNN-` prefix, `--`, and `.log` suffix, the log filename can exceed filesystem path limits (255 bytes on most systems, less on some). No test covers this, and there is no truncation.

---

## 2. Fragile Patterns

### 2.1 Dynamic scoping in `flush_task`

**Lines 158–168**

```bash
flush_task() {
    # Accesses caller's locals (current_task, current_group, in_multiline) via bash dynamic scoping.
    if [[ -n "$current_task" ]]; then
        TASK_GROUPS+=("$current_group")
        TASK_TEXTS+=("$current_task")
        TOTAL_TASKS=$((TOTAL_TASKS + 1))
        current_task=""
        in_multiline=false
    fi
}
```

`flush_task` reads and writes three variables (`current_task`, `current_group`, `in_multiline`) that are declared as `local` inside `parse_tasks`. This relies on bash dynamic scoping: a function inherits the call stack's locals from its caller. It works because `flush_task` is only ever called from within `parse_tasks`'s activation frame.

The risks:
- If `flush_task` is ever called from a different call site (tests, shell sourcing, future refactors), it will access or unintentionally create globals by those names, or — with `set -u` active — crash with "unbound variable".
- Calling `flush_task` from a pipe subshell (e.g., `... | flush_task`) would run it in a child process where modifications to `current_task` and `in_multiline` would not propagate back.
- The comment documents the pattern but readers unfamiliar with bash dynamic scoping will be surprised that a function modifies its caller's locals.

A conventional solution is to pass arguments: `flush_task "$current_task" "$current_group"` and have it modify globals directly, or make the three variables globals themselves (accepting different trade-offs).

---

### 2.2 Colon-delimited multi-value return from `run_claude`

**Lines 489–492, 670–672**

```bash
# run_claude:
local token_info
token_info=$(extract_token_usage "$LOG_DIR/$log_file")   # "TOKENS:WINDOW"
echo "${new_session_id}:${token_info}"                   # "SESSION:TOKENS:WINDOW"

# execute_tasks:
new_session_id=$(echo "$claude_output" | cut -d: -f1)
new_tokens=$(echo "$claude_output" | cut -d: -f2)
new_window=$(echo "$claude_output" | cut -d: -f3)
```

Functions cannot return structured data in bash, so colon-delimited strings are a common workaround. Three specific fragilities:

1. **Field count assumption:** `cut -d: -f3` returns the third colon-delimited field. If `session_id` contains even one `:`, all three values shift and none are correct.
2. **No validation:** there is no check that `$claude_output` contains exactly two colons; a malformed return (e.g., empty string, or error text) silently assigns wrong values to all three variables.
3. **Arithmetic on garbage:** `SESSION_TOKENS=$((SESSION_TOKENS + ${new_tokens:-0}))` — if `new_tokens` is not a number (due to parsing failure), bash arithmetic expands `${new_tokens:-0}` to `0` via the default substitution, masking the problem.

A more robust pattern would write to a temp file or use `declare -g` named return variables (e.g., `_RETURN_SESSION_ID`, `_RETURN_TOKENS`, `_RETURN_WINDOW`).

---

### 2.3 `raw`/`--argjson` flag in `update_task_state`

**Lines 288–301**

```bash
update_task_state() {
    local task_index="$1"
    local field="$2"
    local value="$3"
    local raw="${4:-}"      # pass "raw" for non-string values (numbers, null)

    local val_flag="--arg"
    [[ -n "$raw" ]] && val_flag="--argjson"

    local tmp
    tmp=$(mktemp)
    jq --argjson idx "$task_index" --arg field "$field" $val_flag val "$value" \
        '.tasks[$idx][$field] = $val' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}
```

Issues:

1. **Unquoted `$val_flag`:** the flag variable is word-split into the jq argument list. This works only because `--arg` and `--argjson` contain no whitespace. If the variable's value ever changes form, it silently breaks.
2. **Caller must remember to pass `"raw"` for numbers/null:** there is no type inference. Forgetting `raw` stores a numeric value like `5` as the JSON string `"5"`, which is silent type corruption. The downstream `.attempts` comparisons in jq filters (e.g., `select(.status == "completed")`) are unaffected since they use string fields, but any numeric filter on `attempts` would silently get `null` or wrong results.
3. **Orphaned temp file on jq failure:** if jq fails (e.g., `--argjson val "NaN"` for a non-JSON value string), the `&&` prevents `mv` and `$tmp` is leaked. With `set -e`, jq failure propagates, killing the script before any cleanup.
4. **`null` as a value:** the initial state writes `jj_change: null` via the `jq -n` call (line 265). But subsequent updates write it as a string `update_task_state "$i" "jj_change" "$jj_change"` (no `raw`). The type in the JSON toggles between JSON `null` and the string `"null"`. `get_task_field` with `jq -r` outputs the string `null` for both, so the shell-level check `[[ "$change_id" != "null" ]]` accidentally works, but it's a coincidental type aliasing.

---

### 2.4 `set -euo pipefail` + silent `|| true` suppression

**Lines 427, 539, 344, 351**

Several failure paths suppress errors with `|| true`:

```bash
# compact_session — failure silently returns empty summary
result=$(cd "$TARGET_DIR" && CLAUDECODE= claude ... 2>/dev/null) || true

# analyze_failure — failure silently returns ""
result=$(CLAUDECODE= claude ... 2>/dev/null) || true

# jj_new_change — jj log failure returns "unknown"
change_id=$(cd "$TARGET_DIR" && jj log ... 2>/dev/null || echo "unknown")

# jj_abandon_change — abandon failure silently ignored
(cd "$TARGET_DIR" && jj abandon "$change_id" 2>/dev/null) || true
```

Each of these is defensively intentional, but their combined effect is that every outer-loop operation can silently degrade. `compact_session` returning `""` causes `COMPACTION_SUMMARY=""`, so `run_claude` produces no compaction context; this is the correct fallback. `analyze_failure` returning `""` triggers the `[[ -z "$inner" ]]` fallback (`{"retry": false, ...}`), silently skipping retry analysis. These are not immediately dangerous but make failures hard to diagnose.

---

### 2.5 `echo "$output"` for log writing

**Line 478**

```bash
echo "$output" > "$LOG_DIR/$log_file"
```

`echo` with a value that happens to start with `-` (e.g., `-e`, `-n`) would be interpreted as an `echo` flag on some shells. Claude's JSON output starts with `{`, so this is not an immediate bug, but using `printf '%s\n' "$output"` is unconditionally correct.

Additionally, `echo` appends a trailing newline to the log. When `extract_token_usage` reads the log, jq tolerates trailing newlines in JSON. But when `classify_error` calls `tail -c 3000`, it reads raw bytes including the extra newline — harmless but slightly inconsistent with what Claude actually emitted.

---

### 2.6 Fragile function extraction in tests

**`tests/test-features.sh` lines 95, 131, 232**

```bash
source <(sed -n '/^backoff_sleep()/,/^}/p' "$AGENT_LOOP")
source <(sed -n '/^classify_error()/,/^}/p' "$AGENT_LOOP")
source <(sed -n '/^extract_token_usage()/,/^}/p' "$AGENT_LOOP")
```

The sed range `/^pattern/,/^}/` extracts from the function definition line to the first line that is just `}` at column 0. This works for the current formatting but breaks if:

- A function is reformatted (e.g., body indented differently, `}` appears mid-line in a nested construct).
- Dependencies of the extracted function are not also extracted (e.g., `classify_error` calls `tail` and `grep` — external binaries — which happen to be available, but a future refactor adding a helper function call would silently fail).
- Two functions in sequence: the `}` of the first function would not be confused with the second because the range terminates at the *first* matching `}` line. But if the second function starts immediately after, the sed extraction would be correct. Still, this is the most brittle part of the test suite.

---

## 3. Test Coverage Gaps

### 3.1 `parse_tasks` — entirely untested

Neither test file exercises the parser in isolation. The `--dry-run` tests check that the **banner** shows certain strings (`target:`, `boot:`) but never verify the **content** of parsed tasks. There are no tests for:

| Scenario | Expected behaviour | Currently tested |
|---|---|---|
| Multiline task (indented continuation) | Text is joined with a space | ✗ |
| Tasks with no `##` heading | Assigned to group `"ungrouped"` | ✗ |
| Multiple groups, multiple tasks each | Correct group assignment | ✗ |
| Empty task file | `TOTAL_TASKS=0` | ✗ |
| File with only headings, no tasks | `TOTAL_TASKS=0` | ✗ |
| CRLF line endings | Stripped correctly (or: documented limitation) | ✗ |
| `###` headings | Silently ignored or documented | ✗ |
| Task immediately followed by `##` (no blank line) | Flushed correctly | ✗ |
| `TOTAL_TASKS=0` in `show_parsed_tasks` | No output (not crash) | ✗ |

---

### 3.2 `run_claude` — entirely untested

All tests avoid calling the live Claude CLI. No unit-level tests exist for:

- Colon-delimited return value parsing (session ID extraction, token count, context window).
- Behaviour when Claude exits non-zero (failure path at line 480).
- `COMPACTION_SUMMARY` injection into the prompt (lines 446–457).
- `hint` injection into the prompt (lines 453–457).
- System prompt vs `--resume` selection (lines 466–470).

---

### 3.3 `execute_tasks` — entirely untested

No tests exercise the main execution loop. Missing coverage:

- Model failover toggling between `MODEL` and `FALLBACK_MODEL` across retries.
- `MODEL` reset to `ORIGINAL_MODEL` after each task (line 771).
- `SESSION_TOKENS` accumulation and compaction threshold trigger.
- `COMPACTION_SUMMARY` injection into next task's prompt.
- Auth-error early-break (attempt recorded but no retry).
- AI-driven retry (`analyze_failure` says `false` → task fails; `true` → continues).
- Context-overflow fresh session with hint.
- Failed task marks status `"failed"` and abandons jj change.
- Completed task marks status `"completed"` and stores `session_id`.

---

### 3.4 `init_state` — entirely untested

- State file creation (correct JSON structure, task array, hash).
- Hash mismatch detection and error message.
- Resuming from existing state (skips already-completed tasks).
- `log_name` construction (group slug + task slug truncation).

---

### 3.5 `slugify` — entirely untested

```bash
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}
```

No test verifies:

- Basic conversion (`"Hello World"` → `"hello-world"`).
- Consecutive special characters collapse to single `-`.
- Leading/trailing `-` are stripped.
- Group slug has no length cap (contrast with task slug capped at 50).

---

### 3.6 `write_daily_log` — entirely untested

No test verifies the file is created, the timestamp format, the `DDMMYYYY` filename, or that the `Result:` line is limited to 300 characters.

---

### 3.7 `analyze_failure` — entirely untested

The function depends on the live Claude CLI and the hardcoded `haiku` model. No mock or stub test exists to verify:

- JSON parsing of the inner result.
- Fallback when result is empty.
- Fallback when inner JSON is malformed.

---

### 3.8 `_handle_interrupt` — entirely untested

No test exercises the interrupt handler. Missing:

- `partial_context` written to `state.json` after SIGINT.
- `jj_change` abandoned on interrupt.
- `status` set to `"interrupted"` (only the _display_ of an existing `"interrupted"` status is tested).
- Resume from interrupted task (partial_context injected as hint, attempts reset to 0).

---

### 3.9 `compact_session` — entirely untested

No test for the summarisation call, empty-summary fallback, or session/token counter reset after compaction.

---

### 3.10 `show_status` — partially tested

`test-dir-flag.sh` only tests the "No active run found" path. `test-features.sh` tests that `INT` appears in the output. Missing:

- Completed tasks show `OK`.
- Failed tasks show `FAIL`.
- Progress counts (`$completed/$total completed, $failed failed, $pending pending`).
- Interrupted count shown only when > 0.

---

### 3.11 `show_summary` — entirely untested

The post-execution summary (lines 788–824) is never exercised.

---

### 3.12 `backoff_sleep` — `attempt=0` edge case

**`tests/test-features.sh` lines 97–125**

The tests cover `attempt=1`, `attempt=3`, and the rate-limit doubling. No test covers:

- `attempt=0` (produces `base=1`, which is valid but never occurs in practice).
- `attempt=5` or higher (cap at 60 seconds).
- Rate-limit + high attempt (cap applies before or after doubling — currently after, so `delay=60` not `delay=120`).

---

## 4. Improvement Suggestions

### 4.1 Persist `SESSION_TOKENS` in `state.json` across resumes

**Lines 15, 675**

`SESSION_TOKENS` is an in-memory accumulator reset to 0 on every script invocation. On resume, the existing session may already be near the context limit, but compaction will never trigger because the token counter starts fresh.

**Suggested approach:** add a `session_tokens` field to each task's state entry (or to the group level), update it on each completed task, and restore it when resuming a group's session.

```bash
# On task completion, store cumulative tokens
update_task_state "$i" "session_tokens" "$SESSION_TOKENS" raw

# On resume, when session_id is inherited from completed task
# in the same group, restore SESSION_TOKENS from that task's state
```

---

### 4.2 Fix daily log filename date format

**Line 502**

```bash
local log_file="$LOG_DIR/agent_$(date +%d%m%Y).log"
```

`DDMMYYYY` (e.g., `agent_25022026.log`) sorts alphabetically in the wrong order and is non-standard. The timestamp written _inside_ the file already uses ISO 8601 (`%Y-%m-%d %H:%M:%S` at line 504). The filename should match:

```bash
local log_file="$LOG_DIR/agent_$(date +%Y-%m-%d).log"
```

This makes lexicographic order equal chronological order and is consistent with the internal timestamp format.

---

### 4.3 Make the analysis model configurable

**Line 535**

```bash
result=$(CLAUDECODE= claude -p \
    --model haiku \
```

Replace the hardcoded `haiku` with a variable:

```bash
ANALYSIS_MODEL="${ANALYSIS_MODEL:-haiku}"   # top of script
...
result=$(CLAUDECODE= claude -p \
    --model "$ANALYSIS_MODEL" \
```

Also consider defaulting to `${FALLBACK_MODEL:-haiku}` so that users who specify a fallback model already have a tested API credential path for analysis calls.

---

### 4.4 Cap group slug length in `init_state`

**Lines 252–254**

```bash
group_slug=$(slugify "$group")            # unbounded
task_slug=$(slugify "$task" | cut -c1-50) # capped at 50
```

Group names from real-world task files can be long sentences. A 70-character group slug combined with a 50-character task slug, the 3-character numeric prefix, separator, and `.log` suffix produces a 128-character filename — already problematic on some network filesystems (NFS path limit ≈ 1024 bytes total). Cap the group slug similarly:

```bash
group_slug=$(slugify "$group" | cut -c1-30)
task_slug=$(slugify "$task"  | cut -c1-40)
```

---

### 4.5 Clear `COMPACTION_SUMMARY` at group boundary

**Lines 604–608**

```bash
if [[ "$group" != "$current_group" ]]; then
    current_group="$group"
    session_id=""
    SESSION_TOKENS=0
    COMPACTION_SUMMARY=""   # ADD THIS
fi
```

Without this, a compaction triggered at the end of Group A injects Group A's session summary into Group B's first task, polluting it with unrelated history (see §1.8).

---

### 4.6 Add a `"running"` status to `show_status` pending calculation

**Line 139**

```bash
local running
running=$(jq '[.tasks[] | select(.status == "running")] | length' "$STATE_FILE")
pending=$((total - completed - failed - interrupted - running))
```

And display `"running"` tasks distinctly in the table output (e.g., symbol `RUN`). A process killed with `SIGKILL` leaves tasks stuck in `"running"` state; surfacing this helps the operator decide whether to `--reset`.

---

### 4.7 Replace colon-delimited return from `run_claude` with named globals

**Lines 489–493**

Eliminate the colon protocol entirely in favour of clearly named global return variables:

```bash
_RUN_SESSION_ID=""
_RUN_TOKENS=0
_RUN_CONTEXT_WINDOW=200000

run_claude() {
    ...
    _RUN_SESSION_ID="$new_session_id"
    _RUN_TOKENS="$total"
    _RUN_CONTEXT_WINDOW="$context_window"
    return 0
}
```

The caller then reads `$_RUN_SESSION_ID`, `$_RUN_TOKENS`, `$_RUN_CONTEXT_WINDOW` directly. This is unambiguous regardless of what characters appear in session IDs and removes the `cut -d:` parsing entirely.

---

### 4.8 Separate stdout and stderr in `run_claude`

**Line 475**

```bash
output=$(cd "$TARGET_DIR" && CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>&1) || exit_code=$?
```

Capturing stderr into `$output` contaminates the JSON that jq must parse. Consider writing stderr to a separate file:

```bash
local stderr_file
stderr_file=$(mktemp)
output=$(cd "$TARGET_DIR" && CLAUDECODE= claude "${claude_args[@]}" "$prompt" 2>"$stderr_file") || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    # Append stderr to log for diagnostics
    cat "$stderr_file" >> "$LOG_DIR/$log_file"
fi
rm -f "$stderr_file"
```

This ensures jq parses clean JSON while stderr is still available for debugging.

---

### 4.9 Add `sha256sum` to `check_dependencies`

**Lines 75–85, 233**

`init_state` calls `sha256sum` but `check_dependencies` only checks for `jq` and `claude`. On macOS without Homebrew's `coreutils`, `sha256sum` is absent. The script dies with `sha256sum: command not found` inside `init_state`, far from the helpful error messages in `check_dependencies`. Add:

```bash
if ! command -v sha256sum &>/dev/null; then
    echo "Error: sha256sum is required (macOS: brew install coreutils)" >&2
    exit 1
fi
```

---

### 4.10 Use `printf '%s\n'` instead of `echo` for variable-content output

**Lines 478, 88, 219, 510–513**

`echo "$variable"` is technically undefined when the variable starts with `-` or contains escape sequences in non-bash POSIX shells. The script uses `#!/usr/bin/env bash` and bash's built-in `echo` is safe, but `printf '%s\n' "$variable"` is unconditionally portable and communicates intent (output a string without interpretation). This is especially worth fixing at line 478 (log file writing), where the content is arbitrary Claude output.

---

### 4.11 Model failover strategy: prefer last-successful model

**Lines 719–727, 770–771**

```bash
if [[ "$MODEL" == "$ORIGINAL_MODEL" ]]; then
    MODEL="$FALLBACK_MODEL"
else
    MODEL="$ORIGINAL_MODEL"
fi
...
# Reset model after each task
MODEL="$ORIGINAL_MODEL"
```

The current design toggles between primary and fallback on each retry, then resets to primary at the end of the task. If the primary model has a sustained rate limit, each new task starts with the primary model, fails, then switches to fallback, then resets — wasting one attempt per task.

A better heuristic: if the fallback model was used successfully on the previous task, keep it for the next task (within the same group). Track a `_LAST_SUCCESSFUL_MODEL` variable updated on task completion.

---

### 4.12 `jj_new_change` should capture change ID from `jj new` output, not a second `jj log`

**Lines 342–344**

```bash
output=$(cd "$TARGET_DIR" && jj new -m "$message" 2>&1)
change_id=$(cd "$TARGET_DIR" && jj log -r @ --no-graph -T 'change_id.short()' 2>/dev/null || echo "unknown")
```

Two separate `jj` invocations introduce a TOCTOU window: between `jj new` and `jj log`, `@` could theoretically move (concurrent jj operations, or an auto-rebase). Instead, parse the change ID from `jj new`'s output directly:

```bash
change_id=$(cd "$TARGET_DIR" && jj new -m "$message" --quiet 2>&1 | grep -oP 'Working copy now at: \K\S+' || echo "unknown")
```

Or use `jj log -r 'heads(mutable())' --no-graph -T 'change_id.short()'` immediately after `jj new` which is more semantically correct.

---

### 4.13 Consider a `"running"` → `"pending"` recovery on startup

When the script starts and finds tasks with `"running"` status (indicating a prior SIGKILL), it currently skips them (the skip condition is `completed` or `failed`, not `running`). A running task would therefore be re-executed on resume, which is the desired behaviour. However, `SESSION_TOKENS` starts at 0, so the resumed execution is unaware of prior context accumulation. Additionally, the dangling "running" status is never surfaced to the user via `--status` as a warning. Adding a startup scan that downgrades `"running"` → `"interrupted"` (with a `"recovered_from_kill": true` flag) would make recovery behaviour consistent with the already-implemented interrupt-resume path.

---

*Report generated 2026-02-25. Total issues: 15 bugs/edge cases, 6 fragile patterns, 12 test coverage gaps, 13 improvement suggestions.*
