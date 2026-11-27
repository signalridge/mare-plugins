# Plugins reference

Reference for the 20 plugins in `mare-plugins`: manifest metadata, slash commands, tools and required parameters, Lua service methods, configuration options, and core capability dependencies.

- [Workflow & planning](#workflow--planning): [`goal`](#goal), [`plan-mode`](#plan-mode), [`schedule`](#schedule), [`team`](#team), [`todo`](#todo), [`workflow`](#workflow)
- [Sessions & context](#sessions--context): [`btw`](#btw), [`presets`](#presets), [`session-search`](#session-search), [`session-title`](#session-title), [`time-context`](#time-context)
- [Safety & secrets](#safety--secrets): [`secrets`](#secrets)
- [Execution & search](#execution--search): [`codemode`](#codemode), [`terminals`](#terminals), [`tool-spill`](#tool-spill), [`toolbelt`](#toolbelt)
- [Integrations & diagnostics](#integrations--diagnostics): [`ask_user_question`](#ask_user_question), [`hooks`](#hooks), [`mermaid`](#mermaid), [`peers`](#peers)

## Shared runtime boundaries

### Service scope vs. entry point and optional dependencies

- **Lua-only service contracts (`expose = "lua"`)**: All 11 add-on service contracts (`btw`, `codemode`, `goals`, `plan_mode`, `presets`, `schedule`, `secrets`, `session_title`, `team`, `terminals`, `todo`) set `expose = "lua"`. `scope = "host"` controls lifetime and ownership rather than RPC access; direct RPC calls such as `goals.pause` are rejected (`method_not_found` / not exported).
- **Optional dependency following**: Plugins dynamically follow optional services when loaded and degrade when absent:
  - `goal` and `schedule` follow optional `plan_mode`.
  - `plan-mode` follows optional `usage` (omits the context-usage label in the review dialog when absent).
  - `codemode` follows optional `context` and `commands`.
  - `terminals` follows optional `jobs` (required for `run_in_background = true`).
  - `mermaid` follows optional `commands`.
  - `workflow` follows optional `session`, `context`, `jobs`, `commands`, and `ui`.
  - `team` follows optional `session`, `context`, `ui`, and `commands`.

### Core capability and runtime boundaries

All 20 manifests omit `platforms`, allowing Mare to load them on Linux, macOS, and Windows. Several runtime boundaries apply across plugins:

- `secrets`: Secret projection applies across calls routed through the projecting `llm` service as well as projecting accessors returned by `llm:provider(name)`. `/secrets stored` uses `llm:auth_keys()` (RPC `llm.list_auth_keys`).
- `hooks`: `Stop` runs on `agent/turn-stopping` (`turn_id` and `cancel`) and forwards continuation `{ message, source }`. `PostToolUse` (`result_pipeline`) and `UserPromptSubmit` (`input_admission`) warn and skip if the host lacks those capabilities; `SessionEnd` subscribes to `session/closed`.
- `time-context`: Uses `input_context.timezone` propagated on user messages from `agent:prompt`, `agent:steer`, `agent:enqueue`, and `/retry`, falling back to configured `timezone` or host time when absent or mixed.
- `codemode`: Core defaults `sandbox.execution_mode` to `"per-call"`, so top-level Lua globals reset between calls. Use session-local `store`/`load` unless `cells:get().retains_state` is true.
- `schedule`: `delivery_limits()` sets `background_targets_available = false`. Active durable session inbox delivery requires `agent:enqueue` (with `agent:resume_input` additionally required to resume Plan-mode deferred entries; when `agent:enqueue` is absent, `schedule:run` raises `schedule.schedule_unavailable`).
- `mermaid`: Requires `tools:capabilities().result_pipeline == 1`, `ctx.ui:artifact_image`, `node`, and `mmdc >= 12` (skips registration with a warning if the required core capabilities are absent).

---

## Workflow & planning

### `goal`

Persistent session goals with idle continuation, round and token budgets, completion audits, and optional reference attachments.

- **Category**: `agent` (`provide = { "goals" }`)
- **Injects**: `session`, `agent`, `tools`, `context`, `commands`, `bus`, `policy`, `task` (follows optional `plan_mode`)
- **Tools** (mutating tools require an active model turn with `mare.exec.current()`; native callers use the `goals` service):
  - `get_goal`: no parameters. Returns the current goal, status, budgets, token usage, and elapsed time.
  - `create_goal`: required `objective` (`string`); optional `token_budget` (`integer`), `max_goal_rounds` (`integer`).
  - `update_goal`: required `status` (`"complete" | "blocked" | "paused"`), `goal_id` (`string`), `revision` (`integer`); `blocked_reason` (`string`, must be nonblank when `status = "blocked"`).
- **Command**: `/goal [objective|status|pause|resume|edit <objective>|budget <tokens>|rounds <count>|clear]`
- **Service (`goals`, `expose = "lua"`)**: `get`, `create`, `replace`, `edit`, `pause`, `resume`, `complete`, `block`, `clear` (all `session` scope)
- **Options**:
  - `default_max_rounds` (`integer`, default `256`, min `1`): default round cap for new goals.
  - `blocked_after_consecutive_rounds` (`integer`, default `3`, min `1`): consecutive automatic goal rounds required before the model may mark a goal `blocked`.
  - `max_token_budget` (`integer | nil`, default `nil`, min `1`): optional ceiling and default token budget.
- **Core boundary**: `/goal` reference attachments use `ctx.agent:enqueue` and foreground recovery uses `ctx.agent:resume_input`. Failed or indeterminate enqueue receipts surface an explicit error; if `resume_input` is absent, foreground recovery returns `{ status = "empty" }` (failing only if `stop_reason == "references-pending"`).

### `plan-mode`

Session-scoped planning mode with an active local-write gate and plan review tool. See [plugins/plan-mode/README.md](../plugins/plan-mode/README.md).

- **Category**: `agent` (`provide = { "plan_mode" }`)
- **Injects**: `session`, `context`, `commands`, `ui`, `agent`, `tools`, `bus`, `policy`, `task`, `llm` (follows optional `usage`)
- **Tool**: `exit_plan_mode` (admitted only while plan mode is active or entered). Required `plan` (`string`, Markdown starting with a `# ` heading). Returns `interaction_unavailable` and keeps plan mode active when no interactive responder (`mare.ui.can_respond()`) is available, or `plan_review_stale` if user input is queued.
- **Command**: `/plan [off|status|effort|message]`
- **Service (`plan_mode`, `expose = "lua"`)**: `active`, `state`, `effort` (all `session` scope)
- **Options**:
  - `section` (`string`): system prompt policy text injected while plan mode is active.
  - `plan_effort` (`string | nil`, default `nil`): optional reasoning effort level applied in plan mode.
  - `effort_scope` (`"plan" | "global"`, default `"plan"`): scope of reasoning effort overrides.
  - `enforce` (`boolean`, default `true`): enforce local-write denial (including `todo_write`, `subagent`, `subagent_steer`, `workflow`, `terminal_*`, `job_write`, and `job_kill`), per-call prompts on `peer_send` and `unconfined` tools, and `read-only` sandboxing on confined shells and external tools; `false` falls back to soft guidance.
  - `allow_tools` (`string[]`, default `{}`): tools exempted from the plan-mode gate alongside `exit_plan_mode`.

### `schedule`

Durable scheduled prompts stored in `mare.state` (`schedule.tasks`) plus temporary session-only `/loop` timers. See [plugins/schedule/README.md](../plugins/schedule/README.md).

- **Category**: `agent` (`provide = { "schedule" }`)
- **Injects**: `agent`, `session`, `commands`, `tools`, `bus`, `policy`, `task` (follows optional `plan_mode`)
- **Tools** (delegated subagents with `mare.agent_id` are rejected with `subagent_session`):
  - `schedule_create`: required `title` (`string`), `prompt` (`string`), `rrule` (`string`, `DTSTART` + `RRULE`), `target` (`"current"`). Uses RRULE input rather than `/schedule create`'s timing JSON object.
  - `schedule_list`: optional `active` (`boolean`), `limit` (`integer`), `offset` (`integer`). Lists durable definitions, not `/loop` tasks.
  - `schedule_view`: required `id` (`string`).
  - `schedule_edit`: required `id` (`string`), `action` (`"update" | "delete"`); optional `title`, `prompt`, `rrule`, `target`, `active`, `expected_updated_at` (CAS check).
  - `schedule_set_next_delay`: required `task_id` (`string`), `revision` (`integer`), `run_token` (`string`), `delay_ms` (`integer`, `60000..3600000`), `reason` (`string`). Adjusts the next delay of a running adaptive `/loop` task.
- **Commands**:
  - `/schedule <list|view|create|edit|pause|resume|delete|delete-inactive|run|history|limits> [JSON|id]`
    - Timing selectors in `/schedule create` / `edit` JSON: `kind = "after"` with `after_seconds` (`>= 1`), `kind = "every"` with `every_seconds` (`>= 60`), `at`, `daily`, `weekly`, `cron`, and `rrule`.
  - `/loop [interval] <prompt> | list | pause|resume|stop <id>` (temporary session-scoped loop with 7-day expiry; durable `/schedule` definitions do not expire after 7 days).
- **Service (`schedule`, `expose = "lua"`)**: session loop methods (`create`, `list`, `control`, `submit`) and host durable methods (`create_durable`, `list_durable`, `view`, `edit`, `history`, `delete_inactive`, `run`, `delivery_limits`).
- **Options**:
  - `delivery_history_days` (`integer`, default `30`, `1..3650`): retention window for delivery history.
  - `delivery_history_records` (`integer`, default `200`, `1..10000`): maximum retained records per task.
  - `new_session_interval_seconds` (`integer`, default `60`, `60..604800`): minimum recurring interval for `new` session targets.
- **Delivery, error codes, and return shapes**:
  - `new` and `new_once` targets return `target_runtime_unavailable`; `kind = "session"` targeting a non-current or non-durable session returns `target_unavailable`. `delivery_limits()` reports `background_targets_available = false`.
  - The Lua service `schedule:run` returns `{ id, admitted = false, delivery_floor_ends_at = ... }` if invoked inside the minimum delivery floor. When `ctx.agent:enqueue` is absent, internal delivery fails with `delivery_unavailable` and the public `schedule:run` service raises `schedule.schedule_unavailable`; if only `ctx.agent:resume_input` is missing, enqueue can still succeed and return `admitted = true`. The `/schedule run ID` slash command prints that JSON in a UI notification and returns `{ status = "completed" }` even when `admitted` is `false` (returning `{ status = "rejected", reason = ... }` on errors).
  - Both `agent/input-ready` and `agent/step-ready` are registered via `ctx.policy:voter`, and `/loop` also defers while `plan_mode` is active.
  - Saving a definition, receiving an inbox enqueue receipt, and finishing a model turn are separate stages.

### `team`

Shared multi-agent task board with directed acyclic dependencies, exclusive owner leases, durable session history (`team/task`), and a file-locked JSON mirror under `<state>/team/<session_id>.json`. See [plugins/team/README.md](../plugins/team/README.md).

- **Category**: `agent` (`provide = { "team" }`)
- **Injects**: `tools`, `task`, `bus` (follows optional `session`, `context`, `ui`, `commands`)
- **Tools**:
  - `team_create`: required `title` (`string`); optional `description`, `priority` (`"low" | "medium" | "high"`, default `"medium"`), `blocked_by` (`string[]`, rejects unknown IDs, self-dependencies, and cycles), `owner` (starts `in_progress` if unblocked), `lease_ms`.
  - `team_list`: optional `status` (`"pending" | "in_progress" | "completed" | "cancelled"`), `owner`, `ready_only` (`boolean`), `include_completed` (`boolean`).
  - `team_claim`: optional `id` (omit to claim highest-priority ready unassigned task), `owner` (defaults to `mare.agent_id` or `"main"`), `lease_ms`, `force` (`boolean`).
  - `team_update`: required `id` (`string`); optional `title`, `description`, `status`, `priority`, `owner`, `add_blocked_by`, `remove_blocked_by`, `note`, `renew_lease`, `lease_ms`, `expected_revision`, `lease_token`, `force`.
  - `team_complete`: required `id` (`string`); optional `owner`, `result`, `note`, `expected_revision`, `lease_token`, `force`. Returns `{ task, unblocked }`.
- **Command**: `/team [status|clear|widget on|off]` (no args opens the read-only tabbed inspector on a nonempty board, or prints `Team board is empty.`)
- **Service (`team`, `expose = "lua"`)**: `create`, `list`, `claim`, `update`, `complete`, `clear` (all `session` scope)
- **Bus events (`expose = "lua"`)**: `team/task-created`, `team/task-claimed`, `team/task-updated`, `team/task-completed`, `team/board-cleared`
- **Options**:
  - `default_lease_ms` (`integer`, default `300000` ms, min `1000`): default lease duration on claim/assign.
  - `release_on_agent_end` (`boolean`, default `true`): automatically release active leases held by a subagent on `subagent/completed`.
  - `widget` (`boolean`, default `true`): show compact `above-editor` summary widget.
  - `shared_file` (`boolean`, default `true`): mirror board state to a lock-guarded file under `<state>/team/`.
  - `session_id` (`string | nil`, default `nil`): optional shared parent session ID override (child agents on durable parent sessions automatically discover the parent session via `ctx.session:get`).

### `todo`

Whole-list task checklists with diff tracking, collapsible UI progress widget, and `plan-mode` guard.

- **Category**: `agent` (`provide = { "todo" }`)
- **Injects**: `tools`, `session`, `context`, `commands`, `ui`, `agent`, `policy`
- **Tool**: `todo_write`
  - Required: `todos` (complete array replacing any previous list; pass `[]` to clear). Each entry requires `content` (`string`) and `status` (`"pending" | "in_progress" | "completed"`).
  - Optional: `explanation` (`string`).
  - Rejects writes in child sessions (`tool_context_unavailable`), read-only sessions (`readonly_session`), or when blocked by the `plan-mode` gate while `plan_mode` is active with `enforce = true` (`todo_write` is excluded from plan mode unless `enforce = false` or listed in `allow_tools`).
- **Command**: `/todos [expand|collapse|toggle]`
- **Service (`todo`, `expose = "lua"`)**: `snapshot` (`session` scope)
- **Options**:
  - `allow_parallel_in_progress` (`boolean`, default `false`): allow more than one item to be `in_progress` at once.

### `workflow`

Deterministic Lua multi-agent workflow orchestration running inside a bounded `mare.sandbox` VM, with a live `above-editor` progress panel, optional background job tracking, and durable session records (`workflow/run-start`, `workflow/agent-start`, `workflow/agent-end`, `workflow/run-end`). See [plugins/workflow/README.md](../plugins/workflow/README.md).

- **Category**: `agent`
- **Injects**: `tools`, `task`, `bus` (follows optional `session`, `context`, `jobs`, `commands`, `ui`)
- **Tool**: `workflow` (or custom `tool_name`; registered unconditionally at startup so its name is reserved while disabled, with `/workflow on|off` or `tool_enabled = true` toggling availability; depth limit 1 rejects calls from child subagents)
  - Required: `script` (`string`, Lua ending with `return <json-value>`), `meta` (`{ name, description, when_to_use?, phases? }`, where `name` is lowercase kebab-case 1..64 chars matching `^[a-z][a-z0-9-]*$` with no consecutive `--` and no trailing `-`).
  - Optional: `args` (JSON object exposed as `args`), `run_in_background` (`boolean`, requires optional `jobs` service).
  - Script globals: `agent(prompt, opts?)`, `parallel(fns)`, `pipeline(items, stage1, ...)`, `phase(title)`, `log(msg)`, `args`, `json`. `setTimeout`, `clearTimeout`, and `sleep` are hidden from scripts.
- **Command**: `/workflow [on|off|status]` (persists `workflow_enabled` in `state.json`)
- **Bus events**: emits `workflow/changed`, `workflow/started`, `workflow/phase`, `workflow/log`, `workflow/agent-started`, `workflow/agent-completed`, and `workflow/completed` on `ctx.bus` with bus listener isolation.
- **Options**:
  - Activation and naming: `tool_enabled` (`boolean`, default `false`), `tool_name` (`string`, default `"workflow"`), `provider` (`string`, default `"spawn"`).
  - Execution limits: `max_result_chars` (`50000`), `child_result_chars` (`12000`), `child_timeout_ms` (`7200000` ms), `stop_grace_ms` (`3000` ms, `1..600000`), `max_concurrent_agents` (`0` = auto `min(16, max(1, cpus - 2))`, override via `MARE_WORKFLOW_CPUS`), `max_total_agents` (`1000`), `max_items_per_call` (`4096`), `sync_timeout_ms` (`5000` ms).
  - Progress panel (`panel`): `layout` (`"grid" | "list"`, default `"grid"`), `max_height` (`0.33`, `0.05..1.0`), `cell_width` (`30`, min `12`), `bar` (`"braille" | "block" | "ascii"`, default `"braille"`), `collapse_done` (`true`).

---

## Sessions & context

### `btw`

Complementary controls, parked status indicators, activity state, and transcript overlay layered over the core `conversations` plugin (which owns `/side`, `/btw`, and the `conversations` service). See [plugins/btw/README.md](../plugins/btw/README.md).

- **Category**: `agent` (`provide = { "btw" }`)
- **Injects**: `conversations`, `agent`, `session`, `ui`
- **Service (`btw`, `expose = "lua"`)**: `status`, `transcript`, `view`, `toggle`, `close`, `ask(text, opts?)` (all `session` scope)
- **UI & keymap actions**: `btw:parked` widget (`above-editor`), `btw` right status segment, actions `btw.toggle`, `btw.view`, `btw.close`
- **Intercepted commands in side conversations**: While focused in a side conversation, `btw` blocks `/clear`, `/compact`, `/fork`, `/model`, `/new`, `/rename`, `/resume`, `/retry`, `/rewind`, `/switch`, `/tree`, and `/undo`.
- **Options**:
  - `show_parked_status` (`boolean`, default `true`)
  - `max_turns` (`integer`, default `50`, `1..1000`)
  - `max_output_bytes` (`integer`, default `8192`, `256..1048576`)
  - `max_transcript_bytes` (`integer`, default `65536`, `256..4194304`)

### `presets`

Named combinations of model selection, prompt guidance, and tool declaration constraints (`llm:constrain_tools`), also registered as session-local `ctx.subagent` types. See [plugins/presets/README.md](../plugins/presets/README.md).

- **Category**: `agent` (`provide = { "presets" }`)
- **Injects**: `agent`, `commands`, `context`, `llm`, `session`, `subagent`, `tools`, `bus`
- **Command**: `/preset [id|clear|list|inspect <id>|default [id|clear]|stage [id|clear]|help [id]]`
- **Service (`presets`, `expose = "lua"`)**: `current`, `select` (`session` scope); `set_default`, `stage`, `staged` (`host` scope)
- **Options**:
  - `default` (`string | nil`, default `nil`): preset id applied on fresh or `/new` sessions.
  - `definitions` (`table<string, table>`, default `{}`): map of preset id to `{ name, order, description, default, model, system, prefix, suffix, complete, includeRuntimeContext, tools, denylist }`. Omit `model` to keep the active model; if a configured `model` fails to resolve, the entire preset fails to apply.

### `session-search`

Read-only search and tracing over authorized session history, events, and parent/child sessions.

- **Category**: `agent`
- **Injects**: `tools`, `context`, `query`, `agent`
- **Tools** (each tool is enabled only when `ctx.query:supports(operation)` returns true):
  - `session_search`: optional filters (`query`, `title_query`, `sort_key`, `sort_direction`, `archived`, `session_ids`, `created_from_ms`/`created_to_ms`, `parent_session_ids`, `include_root_sessions`, `availability`, `event_*`). `query` is required unless `title_query` is set.
  - `session_event_search`: required `query` (`string`); optional `session_id` (omit for current session) and event filters (`seq_from`/`to`, `from_ms`/`to_ms`, `event_types`, `surfaces`).
  - `session_trace`: optional `session_id` (`string`, defaults to caller session).
  - `session_event_trace`: required `seq` (`integer >= 1`); optional `session_id` (`string`, defaults to caller session).
  - `session_event_read`: required `event_id` (`string`); optional `before` and `after` (`integer`, `0..10`). Oversized results spill through `mare.spill.save` and return a recovery `handle`.
- **Options**:
  - `max_search_results` (`integer`, default `100`, min `1`)
  - `search_timeout_ms` (`integer`, default `30000`, min `1`)
  - `backend` (`string`, default `""`): spill backend for oversized `session_event_read` results (only `""` or `"local"` is supported).
- **Requirements**: `ctx.agent:activity()`, `ctx.query`, and `mare.spill.save`.

### `session-title`

Automatic naming for writable, saved main sessions from human text messages, using an immediate cleaned prompt-excerpt fallback (truncated by word and byte limits, not sentence punctuation) plus optional background LLM generation. See [plugins/session-title/README.md](../plugins/session-title/README.md).

- **Category**: `agent` (`provide = { "session_title" }`)
- **Injects**: `session`, `llm`, `commands`, `bus`, `task`
- **Command**: `/title [refresh|cancel|rename TEXT]`
- **Service (`session_title`, `expose = "lua"`)**: `get`, `refresh`, `rename`, `cancel` (`session` scope); `register` (`host` scope registration with `generate` callback; requires setting `llm = false` first so the built-in LLM provider is not active)
- **Options**:
  - Cadence and provider:
    - `automatic` (`"first-prompt" | "all-prompts"`, default `"first-prompt"`)
    - `llm` (`boolean`, default `true`): set `false` for excerpt-only naming or before registering a custom provider.
    - `provider` (`string | nil`, default `nil`) and `model` (`string | nil`, default `nil`): explicit model route; must be provided together or both omitted.
  - Size and timing limits:
    - `max_input_bytes` (`integer`, default `8192` bytes, min `1`)
    - `max_tokens` (`integer`, default `128` tokens, min `1`)
    - `timeout_ms` (`integer`, default `15000` ms)
    - `max_title_bytes` (`integer`, default `320` bytes)
    - `fallback_max_bytes` (`integer`, default `80` bytes), `fallback_max_words` (`integer`, default `8`)
    - `target_words` (`integer`, default `6`), `target_cjk_characters` (`integer`, default `16`)

### `time-context`

Durable host time, date, and timezone disclosures injected when a model step is admitted.

- **Category**: `agent`
- **Injects**: `agent`
- **Options**:
  - `refresh_interval_ms` (`integer`, default `600000` ms, min `0`): elapsed-time threshold that triggers a periodic refresh. Earlier disclosures still occur on the first sample, working directory change, host or request date rollover, host or client timezone change, clock rollback, or recovery after an unavailable clock read.
  - `timezone` (`string | nil`, default `nil`): optional IANA or Intl fallback timezone used to format request date/time when user messages do not supply a resolved client timezone.
  - `nonfatal_clock_read_errors` (`boolean`, default `false`): warn and emit an unavailable-clock disclosure instead of failing activation or the step when host clock sampling fails.
- **Timezone precedence**: Host local date and timezone are always sampled via `mare.time.query`. If user messages in the turn carry a single canonical `input_context.timezone` (from `agent:prompt`, `agent:steer`, `agent:enqueue`, or `/retry`), that client timezone formats the request date/time; if mixed or absent, the configured `timezone` fallback is used when set.

---

## Safety & secrets

### `secrets`

Explicit masked secret registration for the active session and plaintext per-profile persistence in `auth.json` (Unix mode `0600`, Windows private DACL). Restores real values only into declared `sensitive_inputs` data fields after explicit tool approval; approved tools can write restored values into workspace files. See [plugins/secrets/README.md](../plugins/secrets/README.md).

- **Category**: `agent` (`provide = { "secrets" }`)
- **Injects**: `commands`, `session`, `agent`, `context`, `llm`
- **Command**: `/secrets [add NAME|save NAME|load NAME|describe NAME|delete NAME|remove NAME|clear|list|stored]`
  - `/secrets describe NAME` displays a notification with the name, configured status, masked preview, and storage note.
- **Service (`secrets`, `expose = "lua"`)**: `register`, `remove`, `list`, `load`, `resolve` (`session` scope); `save`, `delete`, `describe` (returns `{ name, configured, source, scope, writable, masked }`), `stored` (`host` scope)
- **Core boundaries**:
  - Secret values must be at least 5 characters, must not collide with reserved protocol keys or `[[mare-value:` syntax, and must not appear in secret names.
  - Secret projection applies across the projecting `llm` service and projecting accessors returned by `llm:provider(name)`.
  - Single-name `save`, `load`, `describe`, and `delete` work with `mare.projection` and public `llm:auth_get` / `llm:auth_set`; `/secrets stored` and `secrets:stored()` use `llm:auth_keys()` (RPC `llm.list_auth_keys`).

---

## Execution & search

### `codemode`

Executes bounded Lua scripts inside Mare capability cells (`ctx.cells`), letting the model call authorized tools and filter intermediate results in code.

- **Category**: `tools` (`provide = { "codemode" }`)
- **Injects**: `tools`, `cells` (follows optional `context` and `commands`)
- **Tools**:
  - `codemode`: required `input` (`string`, 1..65536 bytes, optionally starting with a first-line `-- @exec: {...}` pragma); optional `yield_time_ms` (`integer`, `0..600000`, default `10000` ms), `max_output_tokens` (`integer`, `0..1000000`, default `10000`), `timeout_ms` (`integer` `1..600000` or `false` to disable). Long scripts yield early with a `cell_id`.
  - `codemode_wait`: required `cell_id` (`string`); optional `yield_time_ms` (`0..600000`, default `10000` ms), `max_output_tokens` (`0..1000000`, default `10000`), `terminate` (`boolean`, `true` cancels the cell and confirms cleanup).
- **Typical two-step flow**:
  1. Call `codemode` with `{ "input": "local out = tools.grep({ pattern = 'TODO' }); store('hits', out); return out.content" }`. If the script runs longer than `yield_time_ms`, Mare returns a `cell_id`.
  2. Call `codemode_wait` with `{ "cell_id": "<id>" }` to collect incremental output, or pass `{ "cell_id": "<id>", "terminate": true }` to stop it.
- **Command**: `/codemode [status|reset|stop [cell_id]]`
- **Service (`codemode`, `expose = "lua"`)**: `available` (`host` scope)
- **Options**:
  - `timeout_ms` (`integer`, default `60000` ms, min `1`): default wall-clock deadline for codemode cells.
- **State retention**: Core defaults `sandbox.execution_mode` to `"per-call"`, so top-level Lua globals and functions do not persist across calls. Use session-local `store(key, value)` and `load(key)` instead unless `cells:get().retains_state` is true.

### `terminals`

Persistent interactive PTY sessions for REPLs and multi-step prompts. See [plugins/terminals/README.md](../plugins/terminals/README.md).

- **Category**: `tools` (`provide = { "terminals" }`, `recommended.cmd = { "bash" }`)
- **Injects**: `tools`, `context`, `task` (follows optional `jobs`)
- **Tools**:
  - `terminal_open`: optional `name`, `cwd`, `type` (registered backend name; defaults to `shell_dialect`).
  - `terminal_send`: required `session_id`, `text` (valid UTF-8, no NUL; the `16384`-byte write cap includes the appended `\r`, so default `submit = true` accepts at most `16383` bytes of `text`); optional `submit` (default `true`), `wait_ms` (`0..timeout_ms`), `run_in_background` (`boolean`, requires `enable_run_in_background = true` and the optional `jobs` service).
  - `terminal_read`: required `session_id`; optional `offset` (`0..scrollback_lines`), `count` (`1..scrollback_lines`, default `500`).
  - `terminal_list`: no parameters.
  - `terminal_signal`: required `session_id`, `signal` (`"SIGINT" | "SIGTERM" | "SIGKILL" | "SIGTSTP" | "SIGHUP"`). Requires `mare.pty.capabilities().foreground_signals` (`false` on Windows). Rejects `SIGKILL` targeting the shell process group itself.
  - `terminal_close`: required `session_id`. Returns `stopped` and `stop_unconfirmed`; check `stopped == true` before assuming the process tree exited.
- **Service (`terminals`, `expose = "lua"`)**: `register` (`host` scope registration with `open` callback), `list` (`host` scope)
- **Options**:
  - Shell selection (`bash` and `pwsh` are built-in backends; an installed shell executable is still required):
    - `shell_dialect` (`"bash" | "pwsh"`, default `"bash"`): on Windows, `bash` resolves `PATH`, `mare.proc.shell()`, and Git Bash under `ProgramFiles`/`ProgramFiles(x86)`; `pwsh` checks `pwsh`, `pwsh.exe`, `powershell.exe`, and `powershell`.
    - `shell` (`string | nil`, default `nil`): explicit shell executable path or name. Applies only to the configured `shell_dialect`; explicitly selecting the other built-in backend via `terminal_open({ type = ... })` clears both `shell` and `shell_args`.
    - `shell_args` (`string[]`, default `{}`): overrides default flags (`--noprofile --norc -i` for `bash`, `-NoLogo -NoProfile` for `pwsh`) for the configured `shell_dialect`.
    - `max_sessions` (`integer`, default `4`), `enable_run_in_background` (`boolean`, default `true`).
  - Buffer and viewport:
    - `buffer_bytes` (`integer`, default `4194304` bytes), `read_max_bytes` (`integer`, default `262144` bytes; must satisfy `read_max_bytes <= buffer_bytes`).
    - `scrollback_lines` (`integer`, default `10000`).
    - `rows` (`integer`, default `40`), `cols` (`integer`, default `160`; must satisfy `rows * cols <= 200000`).
  - Wait and stop timing:
    - `timeout_ms` (`integer`, default `30000` ms), `idle_silence_ms` (`integer`, default `1000` ms), `poll_interval_ms` (`integer`, default `50` ms), `stop_grace_ms` (`integer`, default `3000` ms).
    - `handoff_grace_ms` (`integer`, default `500` ms) and `prompt_tail_grace_ms` (`integer`, default `1000` ms): each must be `0` or `>= poll_interval_ms`.
- **Requirements**: `mare.pty.capabilities()` (`streaming_text`, `terminal_view`, `policy_fence`, `max_write_bytes >= 16384`).

### `tool-spill`

Intercepts oversized tool results via the `tool/result` waterfall, writes complete output to local spill storage, and exposes `read_spill` for paginated retrieval.

- **Category**: `tools`
- **Injects**: `tools`, `session`, `llm`
- **Tool**: `read_spill` (required `handle`; optional `offset`, `limit`, `cursor`)
- **Skipped outputs**: Leaves results untouched when the call was cancelled, the tool name is in `exclude`, or the result sets `no_truncate`, `spill_exempt` (or `details.spill_exempt`), `output_notice`, or `truncated`.
- **Options**:
  - `max_bytes` (`integer`, default `51200` bytes, min `512`)
  - `max_lines` (`integer`, default `2000`, min `3`)
  - `cleanup_period_days` (`integer`, default `30`, min `1`): non-default values (`~= 30`) cannot combine with an explicit `backend`.
  - `exclude` (`string[]`, default `{ "read", "bash", "powershell", "read_spill" }`)
  - `backend` (`string | nil`, default `nil`): only `nil`, `""`, or `"local"` is supported; cannot combine with `root` or a non-default `cleanup_period_days`.
  - `root` (`string | nil`, default `nil`): optional local spill directory override (cannot combine with `backend`).
  - `max_inline_tokens` (`integer | nil`, default `nil`, min `16`)

### `toolbelt`

Read-only wrappers around fast CLI search tools. Skips any tool whose binary is absent on `PATH` or whose name is already present anywhere in the registered tool table. Reports binary status in `mare doctor`.

- **Category**: `tools`
- **Injects**: `tools`
- **Tools**:
  - `grep` (requires `rg`): required `pattern` (regex, or fixed string when `literal = true`); optional `path`, `glob`, `type`, `output_mode`, `-i`, `-n`, `-A`/`-B`/`-C`, `head_limit`, `offset`, `multiline`, `literal`.
  - `find` (requires `fd`): required `pattern` (glob); optional `path`, `head_limit`, `include_ignored`, `include_dirs`.
  - `code_search` (requires `ast-grep`, or `sg` verified via `--version` as `ast-grep`): required `pattern` AND `lang`; optional `path`, `head_limit`.
  - `doc_search` (requires `rga`): required `pattern` (regex); optional `path`, `glob`, `-i`, `output_mode` (`"content" | "files_with_matches"`), `head_limit`.
- **Options**:
  - `grep`, `find`, `code_search`, `doc_search` (`boolean`, all default `true`)
  - `timeout_ms` (`integer`, default `30000` ms, min `1000`)
  - `max_output_bytes` (`integer`, default `1048576` bytes, min `1024`)
  - `head_limit_default` (`integer`, default `250`, min `1`)

---

## Integrations & diagnostics

### `ask_user_question`

Prompts the user through Mare's interactive UI with 1 to 4 structured questions, 2 to 4 options per question, recommendations, optional previews, free text, and skip handling.

- **Category**: `agent`
- **Injects**: `tools`, `session`
- **Tool**: `ask_user_question`
  - Required: `questions` (array of 1..4 objects), each requiring `id` (<= 64 chars, unique), `header` (<= 12 chars), `question` (<= 2000 chars), and `options` (2..4 objects, each requiring `label` <= 120 chars and not `"Other"`, plus `description` <= 1000 chars; optional `recommended` boolean with at most one per question, and `preview` <= 10000 chars).
  - Optional per question: `multi_select` (`boolean`).
  - Availability: inside child agents (`mare.mode == "child"`) or when no interactive responder is connected (`mare.ui.can_respond() == false`), strips internal flow status and returns `{ answers = [], error = { code = "NO_PROVIDER", message = ... } }` with `is_error = true`. User dismissals return `{ answers = [], note = ... }` (`is_error = false`); aborts/interrupts return `code = "ASK_ABORTED"` and disconnects return `code = "DISCONNECTED"`.

### `hooks`

Runs Claude Code and Codex command hooks across 9 lifecycle event names plus Codex legacy `notify`, with sync and bounded async (`MAX_CONCURRENT_ASYNC_HOOKS = 8`) execution. Core boot owns `hooks:subscribe`; this plugin registers `/hooks`, event adapters, and the command runner. See [plugins/hooks/README.md](../plugins/hooks/README.md).

- **Category**: `integration`
- **Injects**: `session`, `llm`, `tools`, `agent`, `commands`, `policy`
- **Command**: `/hooks [status|list|toggle <n>|enable <n>|disable <n>|trust <n>]`
- **Discovery and compatibility**:
  - `discover = true` (or `{ mare, packages, claude, codex, user, project }`) searches `<config>/hooks.json`, `<ws>/.mare/hooks.json`, installed package `hooks/hooks.json` and `hooks.json`, Claude `~/.claude/settings*.json` and `<ws>/.claude/settings*.json` (requires a top-level `hooks` key), and Codex `~/.codex/hooks.json` and `<ws>/.codex/hooks.json`. Project files are skipped unless `mare.trusted == true`, and `hooks` reloads discovered project hooks on `trust/changed`.
  - Codex legacy `notify` maps to `Stop`; `timeoutSec` is accepted only in `dialect = "codex"`.
  - Windows hooks can supply `commandWindows` (or `command_windows`). String commands without `args` require a shell with `argv` transport (`mare.proc.shell().transport == "argv"`).
  - Group `matcher` is ignored on `Stop` and `UserPromptSubmit`.
- **Options**:
  - `sources` (`table[]`, default `{}`): explicit source objects (`{ dialect, path | hooks, plugin_root?, requireTrust?, notify? }`).
  - `discover` (`boolean | table | nil`, default `nil`): auto-discover hook files.
  - `defaultTimeoutMs` (`integer`, default `600000` ms, min `1`)
  - `stderrSummaryMaxChars` (`integer`, default `500`, min `1`)
  - `requireTrust` (`boolean`, default `false`): default SHA-256 trust requirement (individual sources can override `requireTrust`).
- **Core event support**: `PreToolUse`, `SessionStart`, `PermissionRequest`, `PreCompact`, `PostCompact`, Codex `notify`, and `Stop` run when matched (`Stop` uses `turn_id` and `cancel`, while core preserves only the continuation `message` and discards `source`). `PostToolUse` requires `tools:capabilities().result_pipeline == 1` and `UserPromptSubmit` requires `agent:capabilities().input_admission == 1` (registering `agent/input-ready` via `ctx.policy:voter`), warning and skipping if the host lacks either capability. `SessionEnd` subscribes to `session/closed`.

### `mermaid`

Automatically renders completed and streaming `mermaid` / `mmd` Markdown blocks, provides an explicit `mermaid` tool, and adds an interactive Mermaid Viewer. See [plugins/mermaid/README.md](../plugins/mermaid/README.md).

- **Category**: `ui` (`recommended.cmd = { "mmdc" }`)
- **Injects**: `tools`, `ui`, `session`, `bus` (follows optional `commands`)
- **Tool**: `mermaid` (required `source` 1..65536 UTF-8 bytes; optional `format` in `"auto" | "png" | "source"`, `session_id` and `generation` which must be supplied together if either is provided, `profile`)
- **Command**: `/mermaid [view|on|off|toggle|prefs|copy [index]|zoom <50-200|in|out|reset|status>|status]`
- **Viewer keymaps** (transcript scope): `+` / `=` (`mermaid.zoom_in`), `-` (`mermaid.zoom_out`), `0` (`mermaid.zoom_reset`), `s` (`mermaid.toggle_source`), `c` (`mermaid.copy_source`), `[` (`mermaid.prev`), `]` (`mermaid.next`)
- **Options**:
  - Executable and storage:
    - `command` (`string`, default `"mmdc"`): `mmdc` binary name on `PATH` or an absolute path.
    - `node` (`string`, default `"node"`): Node.js executable name or path.
    - `renderer_script` (`string`, default `""`): optional absolute/relative path to `src/cli.js` executed via `node`.
    - `backend` (`string`, default `""`): spill backend (only `""` or `"local"` is supported).
  - Rendering and layout:
    - `automatic` (`boolean`, default `true`), `streaming_preview` (`boolean`, default `true`), `preview_debounce_ms` (`integer`, default `150` ms, `0..2000`).
    - `max_rows` (`integer`, default `20`, `1..200`), `expanded_max_rows` (`integer`, default `200`, `1..296`), `max_cols` (`integer`, default `120`, `4..512`), `max_pixels` (`integer`, default `2048` px, `64..2048`).
    - `scale` (`1 | 2`, default `1`).
    - `preferred_aspect_ratio` (`number`, default `0`; must be `0` for auto or `0.1..10.0`).
    - `node_spacing` (`integer`, default `80` px, `10..400`), `rank_spacing` (`integer`, default `80` px, `10..400`), `node_padding_x` (`integer`, default `40` px, `4..200`), `node_padding_y` (`integer`, default `20` px, `4..200`).
  - Limits and safety:
    - `timeout_ms` (`integer`, default `15000` ms, `100..110000`), `max_nodes` (`integer`, default `100`, `1..10000`), `max_edges` (`integer`, default `200`, `1..20000`), `max_heap_mb` (`integer`, default `512` MB, `128..4096`).
- **Requirements**: `node`, `@mermaid-js/mermaid-cli` (`mmdc >= 12`), `ctx.ui:artifact_image`, and `tools:capabilities().result_pipeline == 1` (warns and skips registering the tool, command, and presenters if the required core capabilities are absent).

### `peers`

Discovers other running local Mare sessions and sends messages or queries status when the core peer client (`mare.peers.connect`) is available.

- **Category**: `integration`
- **Injects**: `tools`, `commands`
- **Tools**:
  - `peer_list`: optional `name` (exact peer name), `cwd` (directory path prefix).
  - `peer_send`: required `to` (`string`), `message` (`string`, UTF-8 length `< 1048576` bytes; messages of `1048576` bytes or more are rejected); optional `pid` and `started_at_ms` (must be provided together to disambiguate duplicate names), `delivery` (`"trigger_turn"` default or `"queue_only"`), `wait` (`boolean`, default `true`), `timeout_ms` (`0..3600000`).
  - `peer_status`: required `to` (`string`); optional `pid` and `started_at_ms` (paired), `wait_idle` (`boolean`, wait for an idle transition instead of only querying status), `current_or_next` (`boolean`, default `true` when `wait_idle = true` to return immediately if already idle; set `false` to wait strictly for the next idle/exit transition), `timeout_ms` (`0..3600000`).
- **Command**: `/peers [name|pid]`
- **Notes**: Sending requires receiver confirmation unless handled by a plugin on the receiver. Delivery receipts confirm enqueue/receipt, not agent turn completion.
