# todo

Whole-list session task checklists with diff tracking, a collapsible `above-editor` progress widget, and `plan-mode` write protection.

## Command

- `/todos [expand|collapse|toggle]`: expand, collapse, or toggle the todo progress widget.

## Tool

- `todo_write`:
  - Required: `todos` (complete array replacing any previous list; pass `[]` to clear). Each entry requires `content` (`string`) and `status` (`"pending" | "in_progress" | "completed"`).
  - Optional: `explanation` (`string`).
  - Rejects writes in child sessions (`tool_context_unavailable`), read-only sessions (`readonly_session`), or while `plan_mode` is active (`plan_mode_active`).

## Lua service (`todo`)

Session-scoped Lua contract (`expose = "lua"`): `snapshot()`.

## Configuration

```lua
mare.plugin("todo", {
  allow_parallel_in_progress = false, -- allow more than one in_progress item at once
})
```

See [docs/plugins.md](../../docs/plugins.md#todo) for full details.
