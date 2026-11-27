# secrets

`/secrets add NAME` opens a masked prompt and registers a hidden value for the current session. The model sees only the secret name and an opaque random reference in its context section.

> **Core boundaries**:
> - **Projecting provider accessor**: `llm:provider(name)` returns a projecting, usage-scoped, generation-bound accessor so direct `stream` / `compact` calls through `llm:provider(name)` mask registered secrets and enforce provider lifecycle cancellation.
> - **Stored-name enumeration**: saving, loading, describing, and deleting credentials by name use `llm:auth_get` / `llm:auth_set`. Listing saved names via `/secrets stored` or `secrets:stored()` uses `llm:auth_keys()` (and RPC `llm.list_auth_keys`).
> - **Value rules**: registered or saved values must be valid UTF-8 of at least 5 characters (`MIN_SECRET_LEN = 5`), must not conflict with `[[mare-value:` syntax or reserved protocol keys, and must not appear inside secret names.

## Commands and storage

- `/secrets add NAME`: prompt via masked input and register a session-only secret.
- `/secrets list`, `/secrets remove NAME`, `/secrets clear`: inspect or revoke active session registrations.
- `/secrets save NAME`: prompt via masked input and save a named secret in the host profile credential file (`auth.json`, plaintext; file mode `0600` on Unix, private DACL on Windows).
- `/secrets load NAME`: re-read a stored name and create a fresh session reference (replacing and revoking any prior reference for that name, even if loading fails).
- `/secrets describe NAME`: displays a notification with the secret name, configured status, masked preview (revealing only a bounded short alphanumeric prefix up to 8 characters before `-`/`_` plus 5 leading and 4 trailing characters when at least 8 characters remain hidden, otherwise all bullets), and plaintext storage note. The Lua service method `secrets:describe(NAME)` returns the full structured record (`name`, `configured`, `source`, `scope`, `writable`, `masked`).
- `/secrets delete NAME`: delete a stored name and revoke its active session registration.
- `/secrets stored`: list saved profile secret names with metadata and masked previews using `llm:auth_keys()` (rejects if address projection makes a namespace ambiguous).

Removing or clearing a session registration leaves saved values in `auth.json` untouched. Saving does not mutate an already approved session reference until you run `/secrets load NAME`.

`secrets` does not scan files, environment variables, or external password stores on startup. The public `secrets:resolve(NAME)` service method (`expose = "lua"`) performs a fresh load and returns `{ reference, source, scope }` without returning the raw value. Child VMs do not inherit parent registrations or permissions; a child can load a known name in its own VM to create its own lease under the same host profile. Record transactions, layered sources, and environment scopes remain unimplemented.

## Projection and tool boundaries

Registered exact values turn into random references on calls routed through the projecting `llm` service (`system`, `messages`, `tools`, and `params`) as well as through accessors returned by `llm:provider(name)`. Tools receive restored real values only in their declared `sensitive_inputs` data fields inside the execution sandbox after explicit approval. Every tool call using a secret requires approval, even if the tool is otherwise auto-allowed. Shell and program text fields reject hidden substitutions; file write/edit content fields accept them as pure data.

Text and reasoning streams buffer a bounded private tail while active or retired registrations exist. Standard UTF-8 tool output snapshots publish only their safe bounded interior; unknown window heads and tails stay withheld. Encoded tool argument fragments and opaque progress updates wait for the final structured result, and cancellation or errors drop incomplete tails. Revoking registrations or switching sessions invalidates old references, while projection-only entries stay in process memory until exit to guard late output.

## Scope limits

`secrets` protects text publication paths through the projecting `llm` service (including `llm:provider(name)` accessors) and new structured session records created after registration. Approved tools can write real values into workspace files, and workspace backups may retain those files for undo. `secrets` does not scrub old records, private HTTP requests outside the projecting `llm` service, arbitrary plugin logs or events, encoded payloads, images, separate child processes or Lua VMs, or malicious plugins. It is not an exfiltration filter.
