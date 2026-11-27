#!/usr/bin/env python3
"""Verify the source fact uses the actual terminal notification renderer."""
import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import fcntl
import json
import pty
import re
import select
import struct
import subprocess
import termios
import time
from pathlib import Path

binary, work, script = sys.argv[1:]
steps = [{"text": "time-tui-finished"}]
if os.environ.get("TIME_TUI_CLOCK"):
    steps = [
        {"error":"unknown model","kind":"model_not_found","retryable":False},
        {"tool_calls":[{"name":"time_probe","arguments":{}}]},
        {"text":"time-tui-finished"},
    ]
Path(script).write_text(json.dumps(steps), encoding="utf-8")
master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 110, 0, 0))
process = subprocess.Popen(
    [binary, "-C", work, "--yolo", "--set", "plugins.onboarding.plugins=false"], stdin=slave, stdout=slave, stderr=slave,
    env=dict(os.environ, TERM="xterm-256color"), start_new_session=True,
)
os.close(slave)
raw = bytearray()
ansi = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")


def until(needle):
    deadline = time.monotonic() + 45
    while needle not in ansi.sub("", raw.decode("utf-8", "replace")):
        assert time.monotonic() < deadline, raw.decode("utf-8", "replace")[-6000:]
        if select.select([master], [], [], 0.1)[0]:
            chunk = os.read(master, 65536)
            raw.extend(chunk)
            # Terminal discovery asks for cursor position before showing the editor.
            if b"\x1b[6n" in chunk:
                os.write(master, b"\x1b[1;1R")
        assert process.poll() is None, "terminal exited early"


def send_when_ready():
    deadline = time.monotonic() + 45
    os.write(master, b"terminal time input")
    while True:
        os.write(master, b"\r")
        step_deadline = min(deadline, time.monotonic() + 1.0)
        while time.monotonic() < step_deadline:
            plain = ansi.sub("", raw.decode("utf-8", "replace"))
            if "time-tui-finished" in plain:
                return
            if select.select([master], [], [], 0.1)[0]:
                chunk = os.read(master, 65536)
                raw.extend(chunk)
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")
            assert process.poll() is None, "terminal exited early"
        if time.monotonic() >= deadline:
            raise AssertionError(raw.decode("utf-8", "replace")[-6000:])


try:
    capture_path = os.environ.get("TIME_CAPTURE")
    if capture_path:
        Path(capture_path).write_text("", encoding="utf-8")
    until("FULL")
    send_when_ready()
    until("time-tui-finished")
    # Model-only context_disclosure stays hidden from the TUI transcript while still reaching the model.
    plain_screen = ansi.sub("", raw.decode("utf-8", "replace"))
    assert "<time_context" not in plain_screen and "Time context: host date" not in plain_screen, plain_screen[-4000:]
    assert b"terminal time input" in raw
    if capture_path:
        requests = [json.loads(line) for line in Path(capture_path).read_text(encoding="utf-8").splitlines() if line.strip()]
        assert requests, "expected captured model requests during TUI turn"
        disclosures = [
            m["context_disclosure"]["state"]
            for req in requests
            for m in req["messages"]
            if m.get("context_disclosure", {}).get("namespace") == "time-context"
        ]
        assert disclosures, requests
        if os.environ.get("TIME_TUI_CLOCK"):
            dates = {d["host"]["local_date"] for d in disclosures}
            assert "2026-11-14" in dates and "2026-11-15" in dates, disclosures
    os.write(master, b"/exit\r")
    deadline = time.monotonic() + 10
    while process.poll() is None:
        assert time.monotonic() < deadline, ansi.sub("", raw.decode("utf-8", "replace"))[-6000:]
        if select.select([master], [], [], 0.1)[0]:
            try:
                raw.extend(os.read(master, 65536))
            except OSError:
                break
    process.wait(timeout=2)
    assert process.returncode == 0
    print("time-context real PTY host-date notification and model response passed")
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
    os.close(master)
