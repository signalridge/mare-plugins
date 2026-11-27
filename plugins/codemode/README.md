# codemode

Executes bounded Lua scripts inside Mare capability cells (`ctx.cells`), letting the model compose authorized tool calls and filter intermediate results in code.

## Tools

- `codemode`: required `input` (`string`, 1..65536 bytes, optionally starting with a first-line `-- @exec: {...}` pragma); optional `yield_time_ms` (`0..600000`, default `10000` ms), `max_output_tokens` (`0..1000000`, default `10000`), and `timeout_ms` (`1..600000` or `false` to disable). Long-running scripts yield early with a `cell_id`.
- `codemode_wait`: required `cell_id` (`string`); optional `yield_time_ms` (`0..600000`, default `10000` ms), `max_output_tokens` (`0..1000000`, default `10000`), and `terminate` (`boolean`, `true` cancels the cell and confirms cleanup).

## Command and Lua service

- `/codemode [status|reset|stop [cell_id]]`: inspect cell status, reset session-local cell state, or stop running cells.
- Service (`codemode`, `expose = "lua"`, `scope = "host"`): `available()`.

## State retention

Core defaults `sandbox.execution_mode` to `"per-call"`, so top-level Lua globals and functions reset between calls. Use session-local `store(key, value)` and `load(key)` unless `cells:get().retains_state` is true.

## Configuration

```lua
mare.plugin("codemode", {
  timeout_ms = 60000, -- minimum 1
})
```

See [docs/plugins.md](../../docs/plugins.md#codemode) for full details.
