# plan-mode

Session-scoped planning mode with an active local-write gate (`enforce = true` by default).

## Behavior

- While plan mode is active and `enforce = true`, Mare denies local write tools, checklist updates (`todo_write`, rejected as `"todo_write is a checklist tool and cannot run in plan mode"`), permission escalations, subagent spawning, steering, or orchestration (`subagent`, `subagent_steer`, `workflow`), persistent terminals (`terminal_*`), and background job control (`job_write`, `job_kill`). Confined shell tools (`bash`, `powershell`) and other confined `external` tools (`side_effect = "external"`, `unconfined ~= true`) run with their local write scope narrowed to `read-only` (when a sandbox control is unavailable on the host and accepted as unavailable, Mare displays the `PARTIAL` sandbox marker while the plan gate itself still requests a read-only sandbox).
- `peer_send` and unconfined external tools (`unconfined = true`, such as MCP or RPC host tools) prompt on every call regardless of their declared `side_effect`. Once approved, their external side effects sit outside the local sandbox and plan mode cannot block them.
- `exit_plan_mode` requires `plan` (a Markdown plan starting with a `# ` heading) and opens the plan review dialog. If no interactive responder is connected (`mare.ui.can_respond() == false`), `exit_plan_mode` returns `interaction_unavailable` and keeps plan mode active. `plan-mode` also follows optional `usage` to show context usage in the review dialog when available.
- `exit_plan_mode` and any tool listed in `allow_tools` bypass the gate, including both local write denials and per-call `unconfined` prompts.
- Network access continues to follow the active permission preset.
- Setting `enforce = false` switches to soft guidance without tool blocking.
- The plan gate and banner exist only while `plan-mode` is loaded, including when resuming a session that saved plan mode as active.
- Running `/plan` while the agent is busy queues the change for the next step. If saving a change fails, plan mode stays on with `"save pending"` in the banner and retries the save on the next step or `/plan` command; plan mode turns off only after the `"off"` save succeeds. Switching sessions drops unsaved choices and loads the target session's saved state.

## Commands and options

- `/plan [message]` or `/plan on`: enter plan mode (optionally submitting or steering a prompt).
- `/plan off`: leave plan mode.
- `/plan status`: show current plan mode state and scoped effort.
- `/plan effort ...`: inspect or override reasoning effort for plan mode.
- `config_schema`: `enforce` (`true`), `allow_tools` (`{}`), `plan_effort` (`nil`), `effort_scope` (`"plan"` or `"global"`), `section` (policy prompt text).
