# schedule

`schedule` stores versioned scheduled task definitions in the public `mare.state` namespace `schedule.tasks`, and provides temporary session-scoped `/loop` timers. Durable definitions survive restarts. Automatic inbox delivery requires Mare to be running, the target to be the current writable durable session, and core support for `ctx.agent:enqueue` (with `ctx.agent:resume_input` additionally required to resume Plan-mode deferred entries). `delivery_limits()` sets `background_targets_available = false`.

## Commands and tools

- `/schedule create JSON`
- `/schedule list`
- `/schedule view ID`
- `/schedule edit JSON`
- `/schedule pause ID`
- `/schedule resume ID`
- `/schedule run ID`
- `/schedule history ID`
- `/schedule delete ID`
- `/schedule delete-inactive`
- `/schedule limits`
- `/loop [interval] <prompt> | list | pause|resume|stop <id>`

Example `/schedule create` payload:

```text
/schedule create {"title":"Check build","prompt":"Check the build results","timing":{"kind":"after","after_seconds":120},"target":{"kind":"session","session_id":"CURRENT_SESSION_ID"}}
```

The seven `/schedule` timing selectors pair `kind` with its value field:

- `kind = "after"` with `after_seconds` (`>= 1`), e.g. `{"kind":"after","after_seconds":120}`
- `kind = "every"` with `every_seconds` (`>= 60`), e.g. `{"kind":"every","every_seconds":60}`
- `kind = "at"`, `kind = "daily"`, `kind = "weekly"`, `kind = "cron"`, and `kind = "rrule"`

Date, timezone, recurrence validation, and occurrence calculations use `mare.time.query`.

Model tools:

- `schedule_create`: requires `title`, `prompt`, `rrule` (`DTSTART` + `RRULE`), and `target` (`"current"`). It does not accept the `/schedule create` timing JSON object as-is.
- `schedule_list`, `schedule_view`, and `schedule_edit`: manage durable definitions (delegated subagents with `mare.agent_id` are rejected with `subagent_session`).
- `schedule_set_next_delay`: requires `task_id`, `revision`, `run_token`, `delay_ms` (`60000..3600000`), and `reason`. Adjusts the next delay for a running adaptive `/loop` task.

Temporary `/loop` tasks stay session-only and expire after seven days; durable `/schedule` definitions do not expire after seven days.

## Targets, error codes, and delivery stages

Keep four stages distinct: creating a temporary `/loop`, saving a durable `/schedule` definition, receiving an inbox enqueue receipt, and completing a model turn.

- **Target errors**: `new` and `new_once` targets return `target_runtime_unavailable` without spawning a child agent. A `kind = "session"` target pointing to a non-current, ephemeral, read-only, or unstable session returns `target_unavailable`.
- **Delivery history vs. completion**: Delivery history confirms durable inbox enqueue via `ctx.agent:enqueue` and records the native input ID and prompt snapshot; it does not confirm that the model turn finished running. Deleting a task stops future deliveries without cancelling messages already in the inbox.
- **Immediate runs (`schedule:run` vs. `/schedule run ID`)**: triggers an immediate delivery while keeping future scheduled occurrences intact.
  - The Lua service `schedule:run` returns `{ id, admitted = false, delivery_floor_ends_at = ... }` if invoked inside the minimum delivery floor. When `ctx.agent:enqueue` is absent, internal delivery fails with `delivery_unavailable` and the public `schedule:run` service raises `schedule.schedule_unavailable`. If `ctx.agent:enqueue` is present and only `ctx.agent:resume_input` is absent, enqueue can still succeed and return `admitted = true`.
  - The `/schedule run ID` slash command prints the result JSON in a UI notification and returns `{ status = "completed" }` even when `admitted` is `false` (it returns `{ status = "rejected", reason = ... }` on errors, displaying `delivery_unavailable: ...` or `target_unavailable: ...` in the notification). Callers checking slash-command status should inspect the payload rather than assuming `status = "completed"` means the prompt was admitted.
- **Concurrency and unconfirmed receipts**: Concurrent edits use namespace revision CAS (external edits can also pass `expected_updated_at`). If an enqueue attempt ends without a confirmed receipt (an unknown ACK), the task stays paused pending reconciliation instead of retrying blindly and risking duplicate prompts. Storage corruption or an unknown schema version fails closed.

## Plan mode, forks, and scheduler loop

`schedule` follows optional `plan_mode` for both durable schedules and `/loop` timers, running plan checks before and after asynchronous reservation publication. It registers policy voters (`ctx.policy:voter`) on both `agent/input-ready` (to defer queued schedule entries if Plan mode turns on before consumption, resuming via `ctx.agent:resume_input` once Plan mode exits) and `agent/step-ready` (to block model steps if Plan mode toggles between input readiness and step start).

Forking a session clears `/loop` tasks and leaves durable definitions pointing at the source session unchanged. If the source session had active `/loop` entries or non-ended durable tasks targeting it, `schedule` emits a non-waking `agent:notify(..., { wake = false })` reminder in the fork. `schedule_create` also guides approximate recurring schedules toward off-peak minutes instead of `0` or `30`.

The provider-owned coroutine wakes on a single next-due `mare.task.sleep` timer or change token, batches due recurring tasks for the same target, drains non-waking `[SCHEDULE CHANGE]` notices before teardown, reconciles unconfirmed receipts, and summarizes coalesced missed runs. Background runtime support (`new`, `new_once`, unloaded session targeting, and archive cleanup) depends on external core background runtime support.
