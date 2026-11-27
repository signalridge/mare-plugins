# terminals

Six tools for persistent interactive PTYs: `terminal_open`, `terminal_send`, `terminal_read`, `terminal_signal`, `terminal_list`, and `terminal_close`. Use `bash` for one-shot commands. Keep the returned `session_id` and close terminals when finished, including before changing permission mode.

## Behavior

Opening a terminal waits for the controlled shell prompt. `terminal_open` and `terminal_send` participate in Mare's command-tool permission rules. `terminal_send` enforces a `16384`-byte write limit that includes the appended `\r`, so the default `submit = true` accepts at most `16383` bytes of `text` (valid UTF-8, no NUL). `terminal_send` reports `prompt`, `stdin_read`, `inferred_idle`, `timeout`, `session_exit`, `wait_elapsed`, or `background`; only the shell status indicates whether the shell itself exited. A foreground send waits up to `wait_ms` and settles with `wait_elapsed` when that wait expires; a concurrent send reports busy while an earlier foreground or background send still owns the terminal.

Cancellation interrupts the foreground operation and keeps the shell open. `terminal_close` discards the shell and attempts to stop its process tree, returning `stopped` and `stop_unconfirmed`; if it returns `stopped = false, stop_unconfirmed = true`, callers must not assume the process tree has exited.

`terminal_signal` requires `mare.pty.capabilities().foreground_signals` (which is `false` on Windows, where `terminal_signal` returns `PTY_SIGNAL_UNSUPPORTED`), and `SIGKILL` targeting the shell process group itself is rejected (use `terminal_close` instead).

`terminal_read` returns bounded VT scrollback history (honoring carriage-return overwrites and alternate-screen mode) plus a bounded current viewport. Background sends (`run_in_background = true`) require `enable_run_in_background = true` and the optional `jobs` service, run on an independent cancellation token decoupled from tool return, and create tracked jobs for `job_output` and `job_kill`.

## Backends, shells, and limits

`terminal_open.type` selects a registered backend (`bash` and `pwsh` are built-in backends; default follows `shell_dialect`, which defaults to `"bash"`). Both built-in backends still require an installed shell executable on the host:

- On Unix, `bash` resolves `bash` on `PATH` and `pwsh` resolves `pwsh` on `PATH`.
- On Windows, `bash` checks `bash`/`bash.exe` on `PATH`, `mare.proc.shell()`, and Git Bash under `ProgramFiles`/`ProgramFiles(x86)`; `pwsh` checks `pwsh`, `pwsh.exe`, `powershell.exe`, and `powershell`.
- Set `shell` to specify an explicit executable path or name, and `shell_args` to override default flags. Both overrides apply only to the configured `shell_dialect`; explicitly opening the other built-in backend via `terminal_open({ type = ... })` clears both `shell` and `shell_args`.

Other plugins can inject `terminals` and call `register(name, backend)` (`expose = "lua"`), which withdraws automatically when the caller unloads. The service contract lives in `init.lua`, with public transport and lifecycle types in `types.lua`. All execution goes through Mare's public `mare.pty` sandbox and policy fence.

Configuration validation enforces `read_max_bytes <= buffer_bytes`, `rows * cols <= 200000`, and `handoff_grace_ms` / `prompt_tail_grace_ms` equal to `0` or `>= poll_interval_ms`.

RPC execution, multi-agent owner lifecycle, daemon containment, and native Windows/macOS acceptance remain integration dependencies beyond the Linux unit suite.
