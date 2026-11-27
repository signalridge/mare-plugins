#!/usr/bin/env python3
"""A denied real TUI prompt remains editable and can be submitted after the hook is repaired."""
import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import importlib.util
import json
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
    work = Path(os.environ["HOOK_INPUT_WORK"])
    requests = Path(os.environ["HOOK_INPUT_REQUESTS"])
    metadata = Path(os.environ["HOOK_INPUT_META"])
    allow = work / "input.allow"
    for path in (requests, metadata, allow, work / "hooks.jsonl"):
        path.unlink(missing_ok=True)
    env = dict(
        os.environ,
        HOOK_INPUT_MODE="deny",
        HOOK_DIALECT="codex",
        MARE_NO_TERM_PROBE="1",
        TERM="xterm-256color",
    )
    tty = terminal.Tty(os.environ["MARE_BIN"], ["--yolo", "--no-session", "-C", str(work)], False, env)
    try:
        tty.ready()
        tty.submit(b"TUI ORIGINAL", until=lambda raw: "INPUT BLOCKED" in terminal.plain(raw))
        assert "INPUT BLOCKED" in terminal.plain(tty.out)
        assert not requests.exists(), "vetoed TUI input reached the provider"
        tty.settle(0.2)
        allow.write_text("repaired", encoding="utf-8")
        tty.submit(b"", until=lambda raw: "input done" in terminal.plain(raw))
        assert "input done" in terminal.plain(tty.out)
        hooks = [json.loads(line) for line in (work / "hooks.jsonl").read_text(encoding="utf-8").splitlines()]
        assert [hook["prompt"] for hook in hooks] == ["TUI ORIGINAL", "TUI ORIGINAL"], hooks
        events = [json.loads(line) for line in metadata.read_text(encoding="utf-8").splitlines()]
        assert len(events) == 2 and events[0]["attempt_id"] != events[1]["attempt_id"]
        tty.quit()
        assert tty.p.returncode == 0
        print("hooks input TUI: actual veto, retained draft and Enter-only repaired resubmission passed")
    finally:
        allow.unlink(missing_ok=True)
        if tty.p.poll() is None:
            tty.quit()


main()
