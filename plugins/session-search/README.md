# session-search

Read-only search and tracing across authorized session history, events, and parent/child session lineage.

## Tools

Each tool is enabled only when `ctx.query:supports(operation)` returns true:

- `session_search`: optional filters (`query`, `title_query`, `sort_key`, `sort_direction`, `archived`, `session_ids`, `created_from_ms`/`created_to_ms`, `parent_session_ids`, `include_root_sessions`, `availability`, `event_*`). `query` is required unless `title_query` is set.
- `session_event_search`: required `query` (`string`); optional `session_id` (omit for current session) and event filters (`seq_from`/`to`, `from_ms`/`to_ms`, `event_types`, `surfaces`).
- `session_trace`: optional `session_id` (`string`, defaults to caller session).
- `session_event_trace`: required `seq` (`integer >= 1`); optional `session_id` (`string`, defaults to caller session).
- `session_event_read`: required `event_id` (`string`); optional `before` and `after` (`integer`, `0..10`). Oversized results spill through `mare.spill.save` and return a recovery `handle`.

## Configuration

```lua
mare.plugin("session-search", {
  max_search_results = 100,  -- minimum 1
  search_timeout_ms = 30000, -- minimum 1
  backend = "",              -- "" or "local"
})
```

## Requirements

Injects `tools`, `context`, `query`, and `agent`; requires `ctx.agent:activity()`, `ctx.query`, and `mare.spill.save`. See [docs/plugins.md](../../docs/plugins.md#session-search) for full details.
