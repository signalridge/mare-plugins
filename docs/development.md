# Development guide

This page covers the repository layout, `mare-plugin.toml` manifest rules, service contract checks, `mare.test` unit specs, and E2E tests.

## Repository layout

- `mare-plugin.toml`: root repository manifest (`name = "signalridge/mare-plugins"`, `version = "1.0.0"`).
- `plugins.toml`: catalog migration table (`[renamed]` and `[deprecated]`) consumed by Mare's plugin manager on startup.
- `NEWS.md`: repository release summary; each plugin also provides `plugins/<name>/NEWS.md` with a matching `## <version>` section surfaced by Mare's `/news` command.
- `plugins/<name>/`: 20 plugin directories containing `mare-plugin.toml`, `init.lua`, `README.md`, `NEWS.md`, optional `lua/<mod>/...` modules, and optional `types.lua`.
- `themes/`: 37 Lua flavor files and `themes/syntax/*.tmTheme`.
- `tests/`: manifest validators, `service-contracts.lua`, `mare.test` unit specs (`tests/specs/`), and Python/Bash E2E scripts.

## Manifest schema

Every plugin directory under `plugins/` must have a `mare-plugin.toml` file (and no legacy manifest filenames anywhere in the repository). `tests/manifests.py` (requires Python 3.11+ `tomllib`) and `tests/test_manifests.py` enforce:

- **Required root fields**:
  - `name`: non-empty string matching the directory name (`plugins/<name>`) and containing no `.`.
  - `version`: non-empty version string matching `.release-please-manifest.json["."]` (updated in lockstep by Release Please across the root manifest and all 20 plugins).
  - `requires`: valid semver requirement string placed at the root table rather than inside `[recommended]`, `[deps]`, or `[provides]`.
  - `description`: non-empty string (for plugin manifests).
  - `category`: one of `agent`, `coding`, `lang`, `tools`, `integration`, `ui`.
- **Optional fields**:
  - `platforms`: non-empty subset of `linux`, `macos`, `windows`. Omitting `platforms` allows Mare to attempt loading the plugin on all three platforms.
  - `keywords`: 2 to 5 non-empty strings.
  - `license`: non-empty string.
  - `[provides]`: non-empty table whose keys come from `tools`, `commands`, `hooks`, `skills`, `prompts`, `themes`, `services`, `flags`, `mcp`, each mapping to a non-empty list of strings.
  - `[deps]`: optional `required` and `optional` string lists.
  - `[recommended]`: accepts only `root` and `cmd` string lists and rejects unknown fields such as `env` or `lua`.
  - `[web]`: when present, requires `dir` (pointing to an existing directory inside the plugin) and supports optional `prefix`, `index`, and `fallback`.
  - `plugins` and `conflicts`: lists of valid plugin names present in the repository.
- **Rejected legacy fields**: `packages`, `extras`, `extensions`, and `recommended.lua`.

Run the manifest checks with:

```sh
python3 tests/manifests.py
python3 tests/test_manifests.py
```

## Service contracts

`tests/service-contracts.lua` validates all 11 service-providing plugins (`btw`, `codemode`, `goal` -> `goals`, `plan-mode` -> `plan_mode`, `presets`, `schedule`, `secrets`, `session-title` -> `session_title`, `team`, `terminals`, `todo`) against Mare's service contract rules. (`hooks` does not provide a service; core boot owns `hooks:subscribe`.)

For each of those 11 service-providing plugins, `tests/service-contracts.lua` checks:

- Every method defines `doc`, `expose` (`lua` or `both`), and `scope` (`host`, `workspace`, or `session`). All 11 add-on contracts currently use `expose = "lua"`, meaning RPC calls cannot invoke them directly even when `scope = "host"`.
- Lua-only methods (`lua`) cannot declare `access`; `both` methods may declare `primary`, `peer`, or `peer_default`.
- Typed methods declare `params` (`type = "object"`), `order` (matching `params.properties` or lua-only option names, with `additionalProperties = false` unless trailing `"..."` is present), and either `result` or `registration = true`.
- Doc-only `lua` methods (for non-JSON parameters such as `mare.Token`) omit `params`, `order`, and `result`.
- Registration methods with callbacks declare `callbacks` mapped to LuaLS `fun(...)` signatures and end `order` with `"..."`.
- Session-scoped methods must not declare a `session_id` parameter.
- Declared contract `events` use valid modes (`emit`, `waterfall`, `vote`, `request`, `policy`) and `expose` values.

Run the contract check with:

```sh
lua tests/service-contracts.lua
```

## Unit specs

Unit tests in `tests/specs/` use Mare's built-in `mare.test` runner (`mare test`), with no external test-runner dependency. Run them in an isolated temporary `MARE_HOME`:

```sh
just specs
# or with an explicit mare binary:
MARE_BIN=/path/to/mare ./tests/run-specs.sh
```

`tests/run-specs.sh` runs `mare test tests/specs` so state-writing specs (`presets`, `schedule`, `workflow`, `team`, etc.) stay off your user `~/.local/state`.

## E2E suite

Run the serial validation and E2E matrix with an explicit `MARE_BIN`:

```sh
MARE_BIN=/absolute/path/to/mare just test
```

What `just test` runs and requires:

- Runs `manifests.py`, `test_manifests.py`, `service-contracts.lua`, `run-specs.sh`, and the E2E scripts listed in `justfile` (including `e2e-workflow.sh` and `e2e-team.sh`), isolating `MARE_HOME` per test and using the local `faux` test provider.
- **Explicit `MARE_BIN`**: several scripts fall back to `../mare/target/debug/mare`, while `tests/e2e-terminal.sh` requires `MARE_BIN` to be set.
- **Host tool prerequisites**: Python 3.11+ (`tomllib`) for manifest checks, `jq` for `tests/e2e-terminal.sh`, Unix PTY modules (`fcntl`, `termios`) for `tests/e2e-themes.py` and `tests/mermaid-pty.py`, and `node` plus `mmdc` for `tests/mermaid-workflow.py`. While the Mermaid adapter accepts `mmdc >= 12`, `tests/mermaid-workflow.py` specifically asserts a `12.x` version string (`startswith("12.")`) and checks for `node` and `mmdc` before probing core capabilities.
- **Allowlisted capability skips (exit code `77`)**: the E2E steps in `justfile` run through `tests/run-e2e-step.sh`. When an allowlisted script exits `77` because the target core build lacks an optional capability or host binary, the wrapper prints `[WAIVED_SKIP] <script>: <reason> [<tracking>]` to stderr, appends that line to `MARE_E2E_SKIP_SUMMARY`, and exits `0`. `just test` prints the full `[WAIVED_SKIP]` summary at the end via `tests/run-e2e-step.sh --print-summary`. Any unlisted script exiting `77` fails the run.
- **Standalone terminal E2E scripts**: `tests/terminal/model_e2e.py` and `tests/terminal/tui_resize_e2e.py` are not wired into `just test`; run them directly when testing interactive terminal model or resize behavior.
