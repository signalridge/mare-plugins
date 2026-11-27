# mare-plugins

Optional plugins and theme flavors for [mare](https://github.com/signalridge/mare) (`1.0.0`, requires Mare `>= 1.0.0`).

[Quick start](#quick-start) · [Plugins](#plugins) · [Themes](#themes) · [Documentation](#documentation) · **English** · [简体中文](README.zh-CN.md)

`mare` ships core file editing, shell execution, and built-in plugins on its own. Add `mare-plugins` when you want extra workflow tools, command hooks, persistent terminals, multi-agent orchestration, or any of the 37 bundled theme flavors.

## Quick start

Add `signalridge/mare-plugins` to `~/.config/mare/init.lua`.

Pick individual plugins with `only` (and pass per-plugin settings under `opts` or `mare.plugin`):

```lua
mare.plugins.add {
  {
    "signalridge/mare-plugins",
    only = { "plan-mode", "todo" },
    opts = {
      ["plan-mode"] = { plan_effort = "high" },
    },
  },
}
```

Use the bundled themes without enabling any plugins (`only = {}`):

```lua
mare.setup {
  flavor = "auto",
  flavor_dark = "catppuccin-mocha",
  flavor_light = "catppuccin-latte",
}

mare.plugins.add {
  { "signalridge/mare-plugins", only = {} },
}
```

Or install all 20 plugins and 37 themes together:

```lua
mare.plugins.add {
  { "signalridge/mare-plugins" },
}
```

Run `mare plugin sync` from your shell, or `/reload` inside Mare. Check loaded plugins with `/plugins`, read release notes with `/news`, and switch flavors with `/theme`.

## Plugins

All 20 plugins omit `platforms` and can load on Linux, macOS, and Windows. See [docs/plugins.md](docs/plugins.md) for full options, Lua service contracts, capability requirements, and runtime boundaries.

| Plugin | Entry point | What it does |
| --- | --- | --- |
| [`ask_user_question`](plugins/ask_user_question/README.md) | `ask_user_question` | Structured multi-choice user prompts with previews, recommendations, and free text. |
| [`btw`](plugins/btw/README.md) | `btw` service, `btw.*` actions | Side-conversation widget, status segment, and transcript viewer over core `conversations`. |
| [`codemode`](plugins/codemode/README.md) | `/codemode`, `codemode`, `codemode_wait` | Bounded Lua script cells for composing tool calls and filtering output. |
| [`goal`](plugins/goal/README.md) | `/goal`, `get_goal`, `create_goal`, `update_goal` | Persistent session goals with idle continuation, budgets, and completion audits. |
| [`hooks`](plugins/hooks/README.md) | `/hooks` | Sync and bounded async Claude Code and Codex command hooks across 9 events plus `notify`. |
| [`mermaid`](plugins/mermaid/README.md) | `/mermaid`, `mermaid` | Automatic Markdown `mermaid`/`mmd` fence rendering and interactive diagram viewer. |
| [`peers`](plugins/peers/README.md) | `/peers`, `peer_list`, `peer_send`, `peer_status` | Local session discovery and confirmed cross-session messaging. |
| [`plan-mode`](plugins/plan-mode/README.md) | `/plan`, `exit_plan_mode` | Session planning mode with an enforcing local-write gate, scoped effort, and plan review. |
| [`presets`](plugins/presets/README.md) | `/preset`, `presets` service | Named model, prompt, and tool-filter presets registered as session subagent types. |
| [`schedule`](plugins/schedule/README.md) | `/schedule`, `/loop`, `schedule_*` | Persistent scheduled prompts (`after`, `at`, `every`, `cron`, `rrule`) and session loops. |
| [`secrets`](plugins/secrets/README.md) | `/secrets`, `secrets` service | Masked session secrets and profile credentials restored only into approved tool fields. |
| [`session-search`](plugins/session-search/README.md) | `session_search`, `session_trace`, `session_event_*` | Read-only search and tracing across authorized session history and child sessions. |
| [`session-title`](plugins/session-title/README.md) | `/title`, `session_title` service | Automatic session naming with prompt-excerpt fallback and optional background LLM titles. |
| [`team`](plugins/team/README.md) | `/team`, `team_*`, `team` service | Shared multi-agent task board with DAG dependencies, owner leases, and durable records. |
| [`terminals`](plugins/terminals/README.md) | `terminal_open`, `terminal_send`, `terminal_read`, `terminal_list`, `terminal_signal`, `terminal_close` | Persistent interactive PTYs (`bash` and `pwsh` backends) for REPLs and multi-step sessions. |
| [`time-context`](plugins/time-context/README.md) | `agent:step_participant` | Durable host date, time, and timezone disclosures injected on model step admission. |
| [`todo`](plugins/todo/README.md) | `/todos`, `todo_write` | Session task checklist with diff tracking, collapsible progress widget, and `plan-mode` guard. |
| [`tool-spill`](plugins/tool-spill/README.md) | `read_spill`, `tool/result` | Spills oversized tool outputs to local storage and returns a paginated recovery handle. |
| [`toolbelt`](plugins/toolbelt/README.md) | `grep`, `find`, `code_search`, `doc_search` | Read-only wrappers for `rg`, `fd`, `ast-grep` (`sg`), and `rga` when installed. |
| [`workflow`](plugins/workflow/README.md) | `/workflow`, `workflow` | Deterministic Lua multi-agent workflows in a sandbox VM with live progress and `/resume`. |

## Themes

Themes are package assets under [themes/](themes/) (25 dark and 12 light flavors, including 13 upstream `.tmTheme` syntax flavors). Enabling any plugin makes all 37 flavors available, or pass `only = {}` for themes alone. See [docs/themes.md](docs/themes.md) for the full flavor list, light/dark pairing, aliases, and contrast checks.

## Documentation

| Page | Covers |
| --- | --- |
| [Mare](https://github.com/signalridge/mare) | Core CLI, plugin loader, and runtime documentation |
| [Documentation hub](docs/README.md) | Index and loading overview for this repository |
| [Plugins reference](docs/plugins.md) | Commands, tools, Lua services, options, capabilities, and runtime boundaries |
| [Themes guide](docs/themes.md) | Light/dark pairing, `/theme`, aliases, contrast checks, and all 37 flavors |
| [Development guide](docs/development.md) | Manifest rules, service contracts, unit specs, and E2E suites |
| [Release notes](NEWS.md) | Version changelog surfaced by `/news` |
| [Contributing](CONTRIBUTING.md) | Prerequisites, manifest conventions, and PR verification checklist |
| [Security policy](SECURITY.md) | Private vulnerability reporting and covered security boundaries |

## Development

```sh
python3 tests/manifests.py
python3 tests/test_manifests.py
lua tests/service-contracts.lua
just specs
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/development.md](docs/development.md) for formatting (`stylua`) and E2E test suites (`just test`).

## License

Distributed under the [MIT License](LICENSE). Third-party `.tmTheme` syntax themes bundled under [themes/](themes/) are attributed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
