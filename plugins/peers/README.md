# peers

Discovers other running local Mare sessions and sends messages or queries status when the core peer client (`mare.peers.connect`) is available.

## Command

- `/peers [name|pid]`: list running local peer sessions or inspect a matching peer.

## Tools

- `peer_list`: optional `name` (exact peer name) and `cwd` (directory path prefix).
- `peer_send`: required `to` (`string`) and `message` (`string`, UTF-8 length `< 1048576` bytes); optional `pid` and `started_at_ms` (paired to disambiguate duplicate names), `delivery` (`"trigger_turn"` default or `"queue_only"`), `wait` (`boolean`, default `true`), and `timeout_ms` (`0..3600000`).
- `peer_status`: required `to` (`string`); optional `pid` and `started_at_ms` (paired), `wait_idle` (`boolean`), `current_or_next` (`boolean`, default `true` when `wait_idle = true`), and `timeout_ms` (`0..3600000`).

## Notes

- Sending requires receiver confirmation unless handled by a plugin on the receiver.
- Delivery receipts confirm enqueue/receipt, not agent turn completion.
- Injects `tools` and `commands`. See [docs/plugins.md](../../docs/plugins.md#peers) for full details.
