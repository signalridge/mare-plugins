# presets

Named presets for model selection, system prompt guidance, and tool declaration constraints.

## Commands

- `/preset`: open an interactive picker showing `(current)`, `(default)`, and `(staged)` badges plus full previews (including validation errors for broken presets); pressing `Esc` keeps the current selection.
- `/preset <id>`: apply a preset while idle.
- `/preset clear`: remove active prompt and tool preferences (keeps the current model).
- `/preset list`: list all definitions and statuses without opening a picker.
- `/preset inspect <id>`: inspect a definition or view validation diagnostics for a broken preset.
- `/preset default [id|clear]`: inspect, set, or clear the persisted default preset (reapplied on fresh or `/new` sessions).
- `/preset stage [id|clear]`: inspect, stage, or clear a one-shot preset for the next fresh or `/new` session.
- `/preset help [id]`: show usage notes or inspect a definition.

## Configuration

Start with a preset that omits `model` so it works with whatever model you already have configured:

```lua
mare.plugins.add {
  {
    "signalridge/mare-plugins",
    only = { "presets" },
    opts = {
      presets = {
        default = "review",
        definitions = {
          review = {
            name = "Review",
            order = 1,
            description = "Review guidance",
            system = "Explain findings before proposing edits.",
            tools = { "read", "grep*" },
            denylist = { "write" },
          },
          -- Optional: add a preset that also switches to a configured model or alias.
          -- If `model` cannot be resolved, the entire preset fails to apply.
          deep_review = {
            name = "Deep Review",
            order = 2,
            description = "Review with an explicit model",
            model = "<your-configured-provider/model-or-alias>",
            system = "Explain findings before proposing edits.",
            tools = { "read", "grep*" },
          },
        },
      },
    },
  },
}
```

Definition fields: `name`, `order`, `description`, `default`, `model`, `system`, `prefix`, `suffix`, `complete`, `includeRuntimeContext` (defaults to `true`), `tools` (allowlist supporting `*` and `?` globs), and `denylist` (denylist supporting `*` and `?` globs).

Configured presets also register as session-local `ctx.subagent` types. The preset picker and the subagent tool share the same registry, and plugins can add types via `ctx.subagent:register_type`. Configured preset names override matching registered types (including built-ins and discovered agents); removing the preset restores the previous type.

## Model and tool constraint behavior

Omit `model` to keep the active model. When `model` is set, `/preset` follows standard `/model` semantics: Mare saves the selected default and updates recent models, preserving pinned alias parameters. If model resolution fails, the preset is rejected as a whole and nothing is applied. `/preset clear` clears only prompt and tool preferences and never rolls back a model change; model selection errors report without claiming rollback.

Omit `tools` to leave declarations unchanged (or apply only `denylist`), or pass `{}` to request zero declarations. `llm:constrain_tools` narrows declarations after request hooks and before executable binding: retries of the same request share one constrained snapshot, fallbacks re-apply the constraint as a new request, and unbound side requests re-apply it per attempt. Permissions apply separately.

Active prompt and tool selections stay in the current live session and clear on session switches, reloads, or restarts, while `set_default` and `stage` persist in `mare.state` for parent sessions. `presets` writes no session journal records and does not pass active selections to forks. Existing user guidance stays intact unless `complete = true` is set; conflicting `complete` replacements or shadowed sections fail validation via `context:preview` before applying.
