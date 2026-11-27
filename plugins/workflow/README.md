# workflow

Deterministic Lua multi-agent workflow orchestration running inside a bounded `mare.sandbox` VM, with a live `above-editor` progress panel, optional background job tracking, and durable session records.

## Activation and command

The `workflow` tool starts disabled by default (`tool_enabled = false`) and toggles persistently in `state.json` (`workflow_enabled`):

- `/workflow on`: enable the `workflow` tool and prompt guidance.
- `/workflow off`: disable the `workflow` tool and prompt guidance.
- `/workflow` or `/workflow status`: show current status and the number of recorded workflow runs in the active session.

## Tool (`workflow`)

The plugin registers `workflow` (or a custom `tool_name`) unconditionally at startup, so the name is already occupied in the tool registry while disabled; `/workflow on` and `/workflow off` toggle its `enabled` predicate and prompt guidance. Parameters:

- `script` (required, `string`): Lua orchestration script ending with `return <json-value>`.
- `meta` (required, `object`):
  - `name` (required, `string`): lowercase kebab-case identifier (1 to 64 chars matching `^[a-z][a-z0-9-]*$`, with no consecutive `--` and no trailing `-`).
  - `description` (required, `string`): one-line run summary.
  - `when_to_use` (optional, `string`)
  - `phases` (optional, array of `{ title, detail?, provider?, model? }`)
- `args` (optional, JSON object): exposed as the `args` global inside `script`.
- `run_in_background` (optional, `boolean`): requires the optional `jobs` service; starts the workflow asynchronously and returns a job ID for `job_output` and `job_kill`.

Subagents cannot start nested workflows (depth limit 1, enforced via `mare.mode == "child"`). Spawned subagents automatically disable `subagent` and `workflow`, strip the exact built-in names (`subagent`, `subagent_wait`, `subagent_steer`, `subagent_cancel`, `subagent_list`) plus the configured `tool_name` from `opts.tools`, and inherit `team = { session_id = origin_session.id }` on durable sessions so child agents share the parent's team board.

## Script globals and helpers

Scripts run inside a bounded Lua sandbox (`max_instructions = 100000000`, `max_pending_calls = 1024`) with `setTimeout`, `clearTimeout`, and `sleep` hidden from user code. A watchdog cancels synchronous slices that make no host progress for `sync_timeout_ms` (default `5000` ms).

- `agent(prompt, opts?)`: spawns a child subagent under the concurrency semaphore and returns its text output (truncated to `child_result_chars`) or validated structured JSON object, or `nil` on subagent failure. Allowed `opts`: `label`, `phase`, `provider` (only `"spawn"` is supported by default), `model`, `effort`, `system`, `cwd`, `tools` (dense string array), and `schema` (restricted JSON Schema with `type = "object"` root supporting `type`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `const`, `oneOf`).
- `parallel(fns)`: runs a dense array of functions concurrently (up to `max_items_per_call`). Returns a packed array with `results.n` and `results.errors` so individual agent failures do not abort sibling work. `results.errors` is a sparse table keyed by 1-based item index; convert it to a dense array (or string-keyed object) before returning it in JSON.
- `pipeline(items, stage1, stage2, ...)`: passes each item through stage functions `fn(val, item, index)` concurrently. Stops an item early if a stage returns `nil` from a failed `agent()` call and records per-item failures in the sparse `results.errors` table.
- `phase(title)`: switches the active phase for subsequent agents and updates the progress panel.
- `log(msg)`: appends a JSON-safe log entry and emits `workflow/log`.
- `args` and `json`: input object and JSON helpers (`json.encode`, `json.decode`, `json.array`, `json.null`).

Example script:

```lua
phase("Analyze")
local reviews = pipeline(args.files, function(file)
  return agent("Inspect " .. file .. " for bugs.", { label = file })
end)
local errors = json.array({})
for i = 1, reviews.n do
  if reviews.errors[i] then
    errors[#errors + 1] = { index = i, error = reviews.errors[i] }
  end
end
return { count = reviews.n, reviews = reviews, errors = errors }
```

## Live panel, events, and session records

- **Progress panel**: foreground runs render an `above-editor` widget (`workflow`) with spinner, progress bar, per-phase grouping, and automatic compaction when terminal height is tight. Registering a `workflow/panel` UI renderer overrides the default layout.
- **Durable history**: on writable non-ephemeral parent sessions, the engine writes serialized monotonic records (`workflow/run-start`, `workflow/agent-start`, `workflow/agent-end`, `workflow/run-end`) and registers a `workflow/run-start` entry renderer so `/resume` reconstructs run summaries (marking unfinished runs `interrupted`). Switching sessions cancels active runs for the previous session.
- **Bus events**: emits `workflow/changed`, `workflow/started`, `workflow/phase`, `workflow/log`, `workflow/agent-started`, `workflow/agent-completed`, and `workflow/completed` on `ctx.bus` with bus listener isolation.

## Configuration

```lua
mare.plugin("workflow", {
  tool_enabled = false,
  tool_name = "workflow",
  max_result_chars = 50000,
  child_result_chars = 12000,
  child_timeout_ms = 7200000,
  stop_grace_ms = 3000, -- 1..600000 ms
  max_concurrent_agents = 0, -- 0 = auto: min(16, max(1, cpus - 2)); override via MARE_WORKFLOW_CPUS
  max_total_agents = 1000,
  max_items_per_call = 4096,
  sync_timeout_ms = 5000,
  provider = "spawn",
  panel = {
    layout = "grid", -- "grid" | "list"
    max_height = 0.33,
    cell_width = 30,
    bar = "braille", -- "braille" | "block" | "ascii"
    collapse_done = true,
  },
})
```
