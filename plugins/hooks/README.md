# hooks

Claude Code and Codex command hooks for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `PreCompact`, `PostCompact`, `Stop`, and `SessionEnd` (plus Codex legacy `notify`). Core boot owns `hooks:subscribe`; this plugin registers `/hooks`, the event adapters, and the external command runner.

> **Core event support**:
> - `PreToolUse`, `SessionStart`, `PermissionRequest`, `PreCompact`, `PostCompact`, Codex `notify`, and `Stop` run when matched. `Stop` uses `agent/turn-stopping` (`turn_id` and `cancel`) and forwards continuation `{ message, source }`.
> - `PostToolUse` requires `tools:capabilities().result_pipeline == 1` and `UserPromptSubmit` requires `agent:capabilities().input_admission == 1`. On hosts lacking either capability, those adapters log a warning and skip registration.
> - `SessionEnd` subscribes to `session/closed` and warns if subscription is unavailable or throws.

Enable `hooks` and configure sources in `~/.config/mare/init.lua`:

```lua
mare.plugins.add {
  {
    "signalridge/mare-plugins",
    only = { "hooks" },
    opts = {
      hooks = {
        discover = true,
        sources = {
          { dialect = "claude-code", path = "/absolute/path/hooks.json" },
        },
      },
    },
  },
}
```

Hook files use `{ "hooks": { "PreToolUse": [{ "matcher": "^bash$", "hooks": [{ "type": "command", "command": "my-check", "timeout": 10 }] }] } }`. You can also pass `hooks` inline on a source or set `discover = true` (or `{ mare, packages, claude, codex, user, project }`) to load hook files automatically. Write Mare tool names in matchers; compatibility aliases match as well.

## Discovery and dialect compatibility

- **Discovered paths**:
  - Mare: `<config>/hooks.json` (user) and `<workspace>/.mare/hooks.json` (project).
  - Installed packages: `<pkg>/hooks/hooks.json` (`claude-code`) and `<pkg>/hooks.json`.
  - Claude Code: `~/.claude/settings.json`, `~/.claude/settings.local.json`, `<workspace>/.claude/settings.json`, and `<workspace>/.claude/settings.local.json` (each must have a top-level `hooks` key).
  - Codex: `~/.codex/hooks.json` and `<workspace>/.codex/hooks.json`.
  - Project-scoped files are skipped with a warning unless `mare.trusted == true`. `hooks` subscribes to `trust/changed` so granting or revoking workspace trust reloads discovered project hooks immediately.
- **Codex compatibility**: legacy `notify` entries map to `Stop`; `timeoutSec` is accepted only when `dialect = "codex"`.
- **Windows and shells**: handlers can set `commandWindows` (or `command_windows`) to override `command` on Windows. Command strings without an explicit `args` array run through the host shell and require `mare.proc.shell().transport == "argv"`.

## Execution and matchers

- Sources run in configuration order.
- `timeout` is in seconds (default `defaultTimeoutMs` = `600000` ms; `SessionEnd` defaults to `1` s and clamps at `3` s).
- Matchers follow Codex rules: empty and `*` match everything, `[A-Za-z0-9_|]` acts as exact pipe-separated alternatives, and anything else compiles as an unanchored Rust `regex` (no lookaround or backreferences). `Stop` and `UserPromptSubmit` ignore group `matcher`, so invalid-matcher rejection applies only to events that evaluate matchers.
- Decision-point hooks (`PreToolUse` on `tool/before`, `PermissionRequest` on `tool/approval`, `UserPromptSubmit` on `agent/input-ready`, and `SessionStart`/`Stop` gating on `agent/step-ready`) register via `ctx.policy:voter`.
- Manage and inspect configured handlers in the TUI with `/hooks` (`/hooks status`, `/hooks list`, `/hooks toggle <n>`, `/hooks enable <n>`, `/hooks disable <n>`, `/hooks trust <n>`).

## Async hooks

Command hooks with `async = true` run on all events except `SessionEnd` (where `async = true` logs a warning and falls back to synchronous execution, matching `openai/codex@336b19ab26`). Async hooks run in a bounded pool (`MAX_CONCURRENT_ASYNC_HOOKS = 8`) without blocking the triggering event, and never veto or alter synchronous gates (`decision`, `ask`, `deny`, and `Stop` `continue: false` or continuation prompts are ignored).

When an async hook completes in the same active session and generation, `additionalContext` is capped or spilled at 64 KiB and queued via non-waking `ctx.agent:notify`. Errors and `systemMessage` entries appear as notifications, and `hooks/audit` records the run. Stale results after session switches or plugin unload drop. Live async processes are cancelled and drained with a bounded timeout by the plugin's unload disposer (on reload or during shutdown after `app/shutdown` listeners return).

## Trust, sandbox, and limits

Hooks run inside the current session sandbox, and no plugin option widens it. Top-level `requireTrust` sets the default, and individual sources can override `requireTrust`. When trust checking is enabled for a source, untrusted handlers (including async hooks) require SHA-256 confirmation via the interactive UI or `/hooks trust <n>` before running. When trust checking is enabled and a source has a `plugin_root`, Mare binds package file content fingerprints into the trust identity and re-verifies them before each run, failing closed on tampering, symlinks, or unreadable files.

Sync errors, timeouts, unspilled oversized output, and invalid structured output deny gating calls; `allow` cannot override another policy's denial. `statusMessage` updates `mare.ui.working` and `hooks` activity. `hooks/audit` records replay on session resume without re-running commands.

`updatedInput`, `updatedPermissions`, `interrupt`, and `prompt` / `agent` / `http` hook types remain unsupported. Transcript files use Mare's format, and `permission_mode` reports `default`. Hook scripts need to be repeatable because core policy or snapshot retries can invoke synchronous hooks more than once for a single tool call; votes are not cached across retries.
