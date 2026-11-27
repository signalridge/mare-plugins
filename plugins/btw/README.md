# btw

Side-conversation controls, parked status indicator, and transcript viewer for [mare](https://github.com/signalridge/mare), built on the core `conversations`, `agent`, `session`, and `ui` services.

The core `conversations` plugin owns `/side`, `/btw`, and the `conversations` service (multi-turn ephemeral forks, frozen parent model and params, structured parent history plus `agent:activity()` snapshots, `ephemeral-read-only` tool execution, and isolated UI contexts). This plugin layers on top without shadowing `/side` or `/btw`:

- **Parked indicator (`btw:parked` widget and `btw` status segment)**: shows when a side conversation is parked via `/side toggle` (note that `/side back` closes and discards the side conversation), along with busy and parent state.
- **Public `btw` service (`expose = "lua"`)**: `status()`, `transcript()`, `view()`, `toggle()`, `close()`, and `ask(text, opts)`.
- **Activity snapshot (`extra.btw`)**: registers open, parked, busy, and turn-count state through `agent:register_activity("btw", ...)` while a side conversation is open.
- **Keymap actions**: `btw.toggle`, `btw.view`, and `btw.close`.
- **Blocked commands while focused in a side conversation**: intercepts `/clear`, `/compact`, `/fork`, `/model`, `/new`, `/rename`, `/resume`, `/retry`, `/rewind`, `/switch`, `/tree`, and `/undo` so session-mutating commands do not run against a side fork (and skips queuing `!cmd` shell-mode submissions).

## Configuration

```lua
mare.plugin("btw", {
  show_parked_status = true,
  max_turns = 50,
  max_output_bytes = 8192,
  max_transcript_bytes = 65536,
})
```
