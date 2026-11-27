# mare-plugins documentation

`mare-plugins` is an optional package (`1.0.0`) of 20 plugins and 37 theme flavors for [mare](https://github.com/signalridge/mare). Each plugin lives under `plugins/<name>/` with its own `mare-plugin.toml` and `init.lua`. Themes live under `themes/` as shared package assets.

## Pages

| Page | Covers |
| --- | --- |
| [Plugins reference](plugins.md) | Commands, tools, required parameters, Lua service methods, options, and capability requirements for all 20 plugins |
| [Themes guide](themes.md) | Selecting flavors, light/dark pairing with `auto`, aliases, contrast checks, and the 37 bundled palettes |
| [Development guide](development.md) | Manifest rules, service contract checks, `mare.test` unit specs, and E2E suites |
| [Release notes](../NEWS.md) | Repository changelog (each enabled plugin also ships `plugins/<name>/NEWS.md` for `/news`) |
| [Repository README](../README.md) | Quick start, plugin index, and repository overview |
| [简体中文 README](../README.zh-CN.md) | Chinese overview and quick start |
| [Contributing](../CONTRIBUTING.md) | Prerequisites, manifest conventions, and PR checks |
| [Security policy](../SECURITY.md) | Private vulnerability reporting and covered boundaries |

## How loading works

Declare `signalridge/mare-plugins` with `mare.plugins.add` in `~/.config/mare/init.lua`. All 20 plugin manifests omit `platforms`, allowing Mare to load them on Linux, macOS, and Windows; runtime availability still depends on core capabilities, frontend support, and external binaries.

- Omit `only` to load all 20 plugins and all 37 themes.
- Set `only = { "hooks", "plan-mode" }` to load only those named plugins while still keeping all 37 themes available.
- Set `only = {}` to skip all 20 plugins and keep only the themes.
- Pass plugin options inside `opts = { <plugin> = { ... } }` or call `mare.plugin("<plugin>", { ... })`. Explicit `mare.plugin` calls take precedence over package `opts`.
- Run `mare plugin sync` from the shell, `/reload` after editing `init.lua`, `/plugins` in Mare's TUI to inspect active status, versions, origins, and startup issues, or `/news` to read release notes.
