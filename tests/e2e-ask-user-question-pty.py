#!/usr/bin/env python3
"""A real TERM=dumb PTY displays and answers the plugin's public UI."""
import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import fcntl
import json
import select
import subprocess
import termios
import time
from pathlib import Path

binary, work, root = sys.argv[1:]
path = Path(root) / "pty-script.json"
question = {"id": "pty", "header": "PTY", "question": "Which displayed target?", "options": [
    {"label": "Alpha", "description": "First", "recommended": True, "preview": "preview line one\npreview line two"},
    {"label": "Beta", "description": "Second"}]}
path.write_text(json.dumps([{"tool_calls": [{"name": "ask_user_question", "arguments": {"questions": [question]}}]}, {"text": "PTY complete"}]), encoding="utf-8")
def exercise(terminal):
    env = dict(os.environ, TERM=terminal, MARE_FAUX_SCRIPT=str(path))
    env.pop("ASK_USER_REPORT", None)
    env.pop("TMUX", None)
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, b"\x20\x00\x64\x00\x00\x00\x00\x00")
    p = subprocess.Popen(
        [binary, "-C", work, "--yolo", "--set", "plugins.onboarding.plugins=false", "--session-id", "ask-pty-" + terminal, "ask"],
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = b""
    def until(marker):
        nonlocal output
        deadline = time.monotonic() + 20
        while marker not in output:
            assert time.monotonic() < deadline, output.decode("utf-8", "replace")
            ready, _, _ = select.select([master], [], [], .1)
            if ready:
                output += os.read(master, 65536)
        previous, output = output, b""
        return previous.decode("utf-8", "replace")
    try:
        if terminal == "dumb":
            shown = until(b"choose 1-")
            assert "Which displayed target?" in shown and "Recommended" in shown and "preview line two" in shown, shown
            os.write(master, b"2\n")
            shown = until(b"choose 1-")
            assert "Review questions" in shown and "Beta" in shown and "Submit answers" in shown, shown
            os.write(master, b"2\n")
        else:
            shown = until(b"Which displayed target?")
            # Wait for the complete popup frame before sending a key.
            if "Recommended" not in shown:
                shown += until(b"Recommended")
            assert "preview" in shown, shown
            os.write(master, b"\x1b[B\r")
            shown = until(b"Review questions")
            if "Submit answers" not in shown:
                shown += until(b"Submit answers")
            os.write(master, b"\r")
        until(b"PTY complete")
        os.write(master, b"/exit\r")
        drain_deadline = time.monotonic() + 10
        while p.poll() is None and time.monotonic() < drain_deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
        p.wait(timeout=10)
        assert p.returncode == 0, output.decode("utf-8", "replace")
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=10)
        os.close(master)

exercise("dumb")
exercise("xterm-256color")
print("ask_user_question actual plain/TUI PTY body/recommendation/preview/selection/review passed")
