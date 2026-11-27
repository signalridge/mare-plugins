#!/usr/bin/env python3
"""Exercise the actual terminal picker and cancellation before real faux requests."""
import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import fcntl
import json
import pathlib
import pty
import re
import select
import struct
import subprocess
import termios
import time

binary, work = sys.argv[1:]
capture = pathlib.Path(os.environ["PRESETS_CAPTURE"])
capture.write_text("", encoding="utf-8")
replies = ["first terminal reply", "cancel terminal reply", "cleared terminal reply"]
pathlib.Path(os.environ["MARE_FAUX_SCRIPT"]).write_text(json.dumps([{"text": text} for text in replies]), encoding="utf-8")
master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
process = subprocess.Popen([binary, "-C", work, "--no-session", "--yolo", "--set", "plugins.onboarding.plugins=false"], stdin=slave, stdout=slave, stderr=slave,
                           env=dict(os.environ, TERM="xterm-256color"), start_new_session=True)
os.close(slave)
raw = bytearray()
ansi = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")


def receive(timeout):
    if select.select([master], [], [], timeout)[0]:
        chunk = os.read(master, 65536)
        raw.extend(chunk)
        if b"\x1b[6n" in chunk:
            os.write(master, b"\x1b[1;1R")
        return True
    return False


def until(text):
    deadline = time.monotonic() + 20
    while text not in ansi.sub("", raw.decode("utf-8", "replace")):
        assert time.monotonic() < deadline and process.poll() is None, raw.decode("utf-8", "replace")[-6000:]
        receive(0.1)
    while receive(0.2):
        assert time.monotonic() < deadline


def send(text, expected=None):
    raw.clear()
    os.write(master, b"\x15" + text.encode() + b"\r")
    if expected is None:
        return
    deadline = time.monotonic() + 20
    while expected not in ansi.sub("", raw.decode("utf-8", "replace")):
        assert time.monotonic() < deadline and process.poll() is None, raw.decode("utf-8", "replace")[-6000:]
        if "startup is still in progress" in ansi.sub("", raw.decode("utf-8", "replace")):
            raw.clear()
            time.sleep(0.3)
            os.write(master, b"\r")
        receive(0.1)
    while receive(0.2):
        assert time.monotonic() < deadline


try:
    until("Ask mare anything")
    send("/preset", "Choose a preset")
    os.write(master, b"review")
    until("PRESET_GUIDANCE")
    raw.clear()
    os.write(master, b"\r")
    until("Ask mare anything")
    send("verify terminal choice")
    until(replies[0])
    send("/preset")
    until("Choose a preset")
    raw.clear()
    os.write(master, b"\x1b")
    until("Ask mare anything")
    send("verify cancelled choice")
    until(replies[1])
    send("/preset clear")
    until("Ask mare anything")
    send("verify cleared choice")
    until(replies[2])
    requests = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
    assert len(requests) == 3, requests
    assert all("PRESET_GUIDANCE" in request["system"] and request["tools"] == ["read"] for request in requests[:2])
    assert "PRESET_GUIDANCE" not in requests[2]["system"] and len(requests[2]["tools"]) > 1
    send("/exit")
    assert process.wait(timeout=10) == 0
    print("presets real PTY picker, prompt preview, Esc cancellation and model tool surface passed")
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
    os.close(master)
