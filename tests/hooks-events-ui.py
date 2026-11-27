#!/usr/bin/env python3
"""Real terminal interaction for installed lifecycle hooks; uses the core's owned PTY driver."""
import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import importlib.util
import time
from pathlib import Path

sys.dont_write_bytecode = True
PTY = Path(__file__).resolve().parent / "pty"  # Vendored Python PTY harness.
sys.path.insert(0, str(PTY))
spec = importlib.util.spec_from_file_location("pty_terminal", PTY / "pty_terminal.py")
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)
terminal.BOOT = 25


@terminal.cleanup.scoped
def main():
    work = Path(os.environ["HOOK_EVENTS_WORK"])
    env = dict(
        os.environ,
        HOOK_STOP_MODE="continue",
        HOOK_DIALECT="codex",
        MARE_NO_TERM_PROBE="1",
        TERM="xterm-256color",
    )
    req_path = Path(os.environ["HOOK_REQUESTS"]) if os.environ.get("HOOK_REQUESTS") else None
    if req_path:
        req_path.write_text("", encoding="utf-8")
    tty = terminal.Tty(os.environ["MARE_BIN"], ["--yolo", "--no-session", "-C", str(work)], False, env)
    try:
        tty.ready()
        tty.submit(b"real TUI hooks", until=lambda raw: "second answer" in terminal.plain(raw))
        visible = terminal.plain(tty.out)
        artifact = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "mare-plugins" / f"hooks-events-tui-{time.time_ns()}.ansi"
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(tty.out)
        assert "second answer" in visible, (artifact, visible[-3000:])
        assert "STOP CONTINUE" in visible, (artifact, visible[-3000:])
        assert "START CONTEXT startup" not in visible, (artifact, visible[-3000:])
        if req_path:
            sent = req_path.read_text(encoding="utf-8")
            assert "START CONTEXT startup" in sent, sent[-3000:]
        tty.quit()
        assert tty.p.returncode == 0
        print(f"hooks lifecycle TUI: real prompt, source disclosure, Stop feedback and completion passed ({artifact})")
    finally:
        if tty.p.poll() is None:
            tty.quit()


main()
