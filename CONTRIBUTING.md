# Contributing to mare-plugins

## Prerequisites

- [StyLua](https://github.com/JohnnyMorganz/StyLua) (`stylua`, pinned to `2.6.0` in CI)
- [ast-grep](https://ast-grep.github.io/) (`ast-grep`, for `scripts/lua_api_rules.py`)
- Python 3 (`python3`)
- Lua 5.4 (`lua`)
- A `mare` 1.0.0+ binary (for `run-specs.sh` and E2E suites)

## Manifest Conventions

- The root `mare-plugin.toml` and each `plugins/<name>/mare-plugin.toml` must declare `name`, `version` (matching `.release-please-manifest.json["."]`), `requires` (`>=1.0.0`), `description`, and `category`.
- Plugin directory names must match their manifest `name` (without `.`).

## Verification Before Opening a PR

Run these checks locally from the repository root:

```bash
just lint
MARE_BIN=/path/to/mare just specs
```

For full E2E coverage across all plugins, run `just test` with `MARE_BIN` pointing to a `faux`-enabled `mare` build.
