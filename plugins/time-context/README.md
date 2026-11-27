# time-context

Injects durable host date, time, and timezone disclosures when a model step is admitted (`agent:step_participant`).

## Behavior

Host local date and timezone are sampled via `mare.time.query`. A fresh disclosure is emitted on the first sample, when `refresh_interval_ms` elapses, on working directory change, host or request date rollover, host or client timezone change, clock rollback, or recovery after an unavailable clock read.

If user messages in the turn carry a single canonical `input_context.timezone` (for example through `agent:enqueue`), that timezone formats the request date/time; otherwise the configured `timezone` fallback is used when set, falling back to host time.

## Configuration

```lua
mare.plugin("time-context", {
  refresh_interval_ms = 600000,       -- minimum 0
  timezone = nil,                     -- optional IANA/Intl fallback timezone
  nonfatal_clock_read_errors = false, -- warn + emit unavailable disclosure on clock failure
})
```

## Requirements

Injects `agent`. See [docs/plugins.md](../../docs/plugins.md#time-context) for full details.
