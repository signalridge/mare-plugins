# tool-spill

Intercepts oversized tool results via the `tool/result` waterfall, writes complete output to local spill storage, and exposes `read_spill` for paginated recovery.

## Tool

- `read_spill`: required `handle` (`string`); optional `offset`, `limit`, and `cursor`.

## Behavior

- Leaves results untouched when the call was cancelled, the tool name is in `exclude`, or the result sets `no_truncate`, `spill_exempt` (`details.spill_exempt`), `output_notice`, or `truncated`.
- When `max_inline_tokens` is configured, measures output with `ctx.llm:measure` when available and falls back to `mare.text.tokens` / `mare.text.image_tokens`.

## Configuration

```lua
mare.plugin("tool-spill", {
  max_bytes = 51200,         -- minimum 512
  max_lines = 2000,          -- minimum 3
  cleanup_period_days = 30,  -- minimum 1
  exclude = { "read", "bash", "powershell", "read_spill" },
  backend = nil,             -- nil, "", or "local" (cannot combine with root or non-default cleanup_period_days)
  root = nil,                -- optional local spill directory override
  max_inline_tokens = nil,   -- optional integer >= 16
})
```

See [docs/plugins.md](../../docs/plugins.md#tool-spill) for full details.
