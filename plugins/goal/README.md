# goal

Persistent session goals with idle continuation, round and token budgets, completion audits, and optional reference attachments.

## Command

- `/goal <objective>`: start or replace the active session goal.
- `/goal status`: show current objective, status, round/token budgets, and elapsed time.
- `/goal pause | resume | clear`: pause, resume, or clear the active goal.
- `/goal edit <objective> | budget <tokens> | rounds <count>`: update goal fields.

## Tools

Mutating tools require an active model turn (`mare.exec.current()`); Lua callers can use the `goals` service directly.

- `get_goal`: no parameters. Returns the current goal, status, budgets, token usage, and elapsed time.
- `create_goal`: required `objective` (`string`); optional `token_budget` (`integer`), `max_goal_rounds` (`integer`).
- `update_goal`: required `status` (`"complete" | "blocked" | "paused"`), `goal_id` (`string`), `revision` (`integer`); `blocked_reason` (`string`, required and nonblank when `status = "blocked"`).

## Lua service (`goals`)

Session-scoped Lua contract (`expose = "lua"`): `get`, `create`, `replace`, `edit`, `pause`, `resume`, `complete`, `block`, and `clear`.

## Configuration

```lua
mare.plugin("goal", {
  default_max_rounds = 256,               -- minimum 1
  blocked_after_consecutive_rounds = 3,   -- minimum 1
  max_token_budget = nil,                 -- optional integer >= 1
})
```

See [docs/plugins.md](../../docs/plugins.md#goal) for full details and `plan_mode` / `agent:enqueue` boundaries.
