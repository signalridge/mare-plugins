# session-title

Names writable, saved main sessions from human text messages, using an immediate cleaned prompt-excerpt fallback followed by optional background LLM generation. Manual renames pin the title until you run `/title refresh`.

The fallback strips basic Markdown formatting and extra whitespace from the first eligible human message, then truncates by `fallback_max_words` (default `8`) and `fallback_max_bytes` (default `80`) rather than splitting on sentence punctuation.

## Commands

- `/title`: show the current session title.
- `/title refresh`: re-run title generation.
- `/title rename TEXT`: set an explicit manual title.
- `/title cancel`: cancel in-flight title generation.

## Configuration

- `automatic` (`"first-prompt"` default, or `"all-prompts"`): `"all-prompts"` anchors on the existing generated title and keeps the wording unchanged when the topic stays the same. New user input supersedes older pending work, and conditional session writes stop stale results from overwriting a manual name.
- `llm` (`boolean`, default `true`): set `false` to use only the immediate prompt-excerpt fallback or before registering a custom title provider.
- `provider` and `model` (`string | nil`): explicit model route (requires both nonempty, or omit both to use the main request model).
- Limits: `max_input_bytes` (`8192`, oversized input errors), `max_tokens` (`128`), `timeout_ms` (`15000`), `max_title_bytes` (`320`), `fallback_max_bytes` (`80`), `fallback_max_words` (`8`), `target_words` (`6`), `target_cjk_characters` (`16`).

## Service (`session_title`, `expose = "lua"`)

Exposes `get`, `refresh`, `rename`, `cancel`, and `register`. A custom provider calls `register({ id, automatic, generate })` after `llm = false` disables the default LLM generator. `generate` receives the session version, human messages, current model, stable title anchor, and cancellation token, returning `{ title, message_ids?, model? }`. Removing a provider cancels its active work and drains its tasks.
