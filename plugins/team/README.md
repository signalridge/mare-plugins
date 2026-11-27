# team

Shared multi-agent task board with directed acyclic dependencies, exclusive owner leases, durable session history, and a file-locked JSON mirror so parent and child agents coordinate across VMs.

## Command and UI

- `/team`: open a read-only tabbed task inspector (`All`, `Ready`, `Active`, `Blocked`, `Done`) with live task previews when tasks exist, or notify `Team board is empty.` when the board is empty.
- `/team status`: notify counts of total, active, ready, blocked, and completed tasks.
- `/team clear`: clear all tasks on the current session's board.
- `/team widget on|off`: show or hide the compact `above-editor` summary widget.

Active and pending tasks are also injected into model context via the `team:board` section.

## Tools

- `team_create`: required `title` (`string`); optional `description`, `priority` (`"low" | "medium" | "high"`, default `"medium"`), `blocked_by` (array of existing task IDs; rejects unknown IDs, self-dependencies, and cycles), `owner` (starts `in_progress` immediately if unblocked), and `lease_ms`.
- `team_list`: optional `status` (`"pending" | "in_progress" | "completed" | "cancelled"`), `owner`, `ready_only` (`boolean`), and `include_completed` (`boolean`). Returns `{ tasks, counts }`.
- `team_claim`: optional `id` (omit to claim the highest-priority ready unassigned task, breaking ties by creation sequence), `owner` (defaults to `mare.agent_id` or `"main"`), `lease_ms`, and `force` (`boolean`, overrides an active lease held by another owner).
- `team_update`: required `id`; optional `title`, `description`, `status`, `priority`, `owner`, `add_blocked_by`, `remove_blocked_by`, `note`, `renew_lease` (`boolean`), `lease_ms`, `expected_revision` (`integer`), `lease_token` (`string`), and `force` (`boolean`).
- `team_complete`: required `id`; optional `owner`, `result`, `note`, `expected_revision`, `lease_token`, and `force`. Marks the task `completed`, clears its lease, and returns `{ task, unblocked }`.

## Leases, concurrency, and persistence

- **Optimistic concurrency and lease guards**: claiming or assigning a task issues a `lease_token`, `lease_expires_at_ms`, and incremented `revision`. A competing `claim` against an active lease returns `team.lease_conflict` unless `force = true`. On `team_update`, `force = true` bypasses owner (`team.stale_owner`) and lease-expiry checks and permits transitioning out of terminal states (`completed` / `cancelled`) or completing a `cancelled` task. On `team_complete`, `force = true` bypasses owner and lease-expiry checks (a `cancelled` task still cannot be completed via `team_complete`). On both tools, a supplied stale `expected_revision` still returns `team.conflict`, and a supplied stale `lease_token` still returns `team.stale_lease`.
- **Automatic subagent lease release**: when `release_on_agent_end = true` (default), `team` listens to `subagent/completed` and releases active leases held by the finished subagent (scoped to matching parent session and generation).
- **Cross-VM coordination**: writes are serialized with an in-VM FIFO queue and `mare.lock.file` (`5000` ms timeout) over `<state>/team/<session_id>.json` (mode `0600` on Unix) via a private host-context worker when `shared_file = true`, so mutating tools work under default `auto` (`workspace-write`) sandboxes as well as `full-access`. Parent sessions record mutations as durable `team/task` session records and flush child-originated disk mutations back into the session journal so `/resume` restores the complete board. Read-only sessions reject mutations.

## Lua service (`team`) and events

`team` publishes a session-scoped Lua contract (`expose = "lua"`): `create(args)`, `list(opts?)`, `claim(args?)`, `update(args)`, `complete(args)`, and `clear()`.

Bus events (`expose = "lua"`): `team/task-created`, `team/task-claimed`, `team/task-updated`, `team/task-completed`, and `team/board-cleared`.

## Configuration

```lua
mare.plugin("team", {
  default_lease_ms = 300000, -- minimum 1000
  release_on_agent_end = true,
  widget = true,
  shared_file = true,
  -- session_id = nil, -- optional override; child agents discover the parent session automatically via core session metadata
})
```
