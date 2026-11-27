# mermaid

`mermaid` renders completed and streaming `mermaid` and `mmd` Markdown fences through Mare's public Markdown presenter registry and adds an explicit `mermaid` tool (required parameter: `source`; if either `session_id` or `generation` is provided, both must be supplied together). Rendering follows normal external-tool approval and sandbox policy.

## Requirements

This plugin requires a core exposing `tools:capabilities().result_pipeline == 1`, `ctx.ui:artifact_image`, and durable tool-state support (protocol `3.0`). If the required capabilities are absent, the plugin logs a warning at startup and skips registering the `mermaid` tool, `/mermaid` command, and Markdown fence presenters.

It installs no packages on its own. Install Node and `@mermaid-js/mermaid-cli` **12 or later** on `PATH` (or configure `command` / `renderer_script` with an absolute path); version 12+ writes PNGs to stdout so no temporary directory is needed. Verify with `node --version` and `mmdc --version`.

In a Node project, you can pin `@mermaid-js/mermaid-cli@12.0.0` as a dev dependency and point `command` to `node_modules/.bin/mmdc`. Mermaid CLI also needs its supported Puppeteer/Chromium installation. The plugin adds no `--no-sandbox` flags and makes no offline promise; if the sandbox blocks browser launch, Mare returns the source and tool error.

## Configuration

```lua
mare.plugins.add {
  {
    "signalridge/mare-plugins",
    only = { "mermaid" },
    opts = {
      mermaid = {
        command = "mmdc",
        node = "node",
        timeout_ms = 15000,
        automatic = true,
        streaming_preview = true,
        preview_debounce_ms = 150,
        max_rows = 20,
        expanded_max_rows = 200,
        max_cols = 120,
        max_pixels = 2048,
        scale = 1,
        preferred_aspect_ratio = 0,
        node_spacing = 80,
        rank_spacing = 80,
        node_padding_x = 40,
        node_padding_y = 20,
        max_nodes = 100,
        max_edges = 200,
        max_heap_mb = 512,
      },
    },
  },
}
```

`renderer_script` names an optional `src/cli.js` entrypoint run with `node` to bypass platform command wrappers. On Windows the adapter also checks `PATH` for the standard npm CLI entrypoint (Windows execution has not been validated in the Linux test suite). Validation constraints: `scale` must be `1` or `2`, `preferred_aspect_ratio` must be `0` (auto) or `0.1..10.0`, and `backend` accepts only `""` or `"local"`. Mermaid source and rendering profile travel on stdin; process arguments use fixed adapter flags or trusted settings.

## Viewer and commands

- `/mermaid` or `/mermaid view`: open the interactive Mermaid Viewer (`+`/`=` and `-` for 50% to 200% zoom, `0` to reset, `s` to toggle source, `c` to copy active source, `[`/`]` to switch active diagrams).
- `/mermaid copy [index]`: copy raw diagram source.
- `/mermaid on|off|toggle|prefs|status`: control automatic fence rendering.
- `/mermaid zoom <50-200|in|out|reset|status>`: adjust inline zoom and re-render.

Expanded fences render at `expanded_max_rows` (default `200`) followed by the full source. Because the terminal owns native scrollback and sends no scroll notifications, press `Ctrl+T` after reflow to rematerialize older image references. Cancellation or timeout discards late results; settling the tool does not wait for every descendant browser process to exit.

## Caching, fallback, and RPC consumers

PNG bytes are validated and stored through `mare.spill.save_bytes`. Ephemeral sessions store `mermaid/artifact` records in memory (lack of disk persistence does not force a fallback to source). Persisted `mermaid/artifact` records contain `key`, `spill_id`, `sha256`, `media_type`, `bytes`, `session_id`, `renderer`, `width`, `height`, and optional `backend`; the full `profile` stays in the active viewer state rather than the artifact journal record, and tool/model text holds no raw image bytes. Resumed sessions verify the artifact digest before display. The native materialization cache enforces a 32 MiB byte budget, 64-entry ceiling, and 8 MiB per-image read limit, scoped per image resolver instance (so reloaded resolvers or different sessions never share cached images) and session epoch.

Image sizing adapts to 4-column width buckets, cell dimensions, aspect ratio, `max_nodes`, `max_edges`, `max_heap_mb`, `mmdc -j 1`, and the adapter timeout. The render profile derives light/dark mode from the active theme's `code_bg`, and theme or resize changes request a fresh profile. Clients without image support skip automatic fence rendering and receive the original Markdown source without spawning a renderer; calling the explicit `mermaid` tool with `format = "png"` follows the PNG render branch (`format = "source"` returns source).

For RPC image consumers:

- Handshake uses `protocol_version = "3.0"` (core requires the same major version).
- Submit Markdown via `ui.render_markdown` and read rendered results via `ui.get_markdown`.
- Advertise image capabilities with viewport fields `supports_images` and `supports_artifact_images`.
- Core emits image resource entries in the `output` namespace whose JSON key contains `session_id`, `session_epoch`, `spill_id`, and `sha256`. Call `spill.read` on the same connection passing that `spill_id` (with `session_id` and `encoding = "base64"`). A default `spill.read` returns at most 1 MiB (`1048576` bytes), so hashing a single default response rejects valid PNGs larger than 1 MiB: either follow `next_offset` until exhausted, base64-decoding and concatenating each page before computing `sha256`, or pass `limit = 8388608` to cover the 8 MiB image ceiling in one read. Consumers declaring only `supports_images` (without `supports_artifact_images`) receive the source plus a capability diagnostic.

## Testing

Run the end-to-end test with Node and `mmdc` installed (requires `mmdc >= 12`):

```sh
MARE_BIN=/path/to/matching/mare tests/e2e-mermaid.sh
```

Run the native terminal Kitty-protocol test (loads its PTY harness from `tests/pty` in this repository):

```sh
MARE_BIN=/path/to/matching/mare python3 tests/mermaid-pty.py
```

The Node adapter uses only Node standard library APIs. Separately installed [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli#readme) is MIT licensed by its contributors.
