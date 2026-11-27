# toolbelt

Read-only wrappers around fast CLI search tools (`rg`, `fd`, `ast-grep`, and `rga`). Each tool is registered only when its binary is found on `PATH` and the tool name is not already registered by core or another plugin. Binary availability is reported in `mare doctor`.

## Tools

- `grep` (requires `rg`): required `pattern` (regex, or fixed string when `literal = true`); optional `path`, `glob`, `type`, `output_mode`, `-i`, `-n`, `-A`/`-B`/`-C`, `head_limit`, `offset`, `multiline`, `literal`.
- `find` (requires `fd`): required `pattern` (glob); optional `path`, `head_limit`, `include_ignored`, `include_dirs`.
- `code_search` (requires `ast-grep`, or `sg` verified via `--version` as `ast-grep`): required `pattern` and `lang`; optional `path`, `head_limit`.
- `doc_search` (requires `rga`): required `pattern` (regex); optional `path`, `glob`, `-i`, `output_mode` (`"content" | "files_with_matches"`), `head_limit`.

## Configuration

```lua
mare.plugin("toolbelt", {
  grep = true,
  find = true,
  code_search = true,
  doc_search = true,
  timeout_ms = 30000,          -- minimum 1000
  max_output_bytes = 1048576,  -- minimum 1024
  head_limit_default = 250,    -- minimum 1
})
```

See [docs/plugins.md](../../docs/plugins.md#toolbelt) for full details.
