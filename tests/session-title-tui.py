"""Verify title commands and restoration in the real terminal renderer."""

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

binary, work = sys.argv[1:]
ansi = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")


def run(*args, restored=False):
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 110, 0, 0))
    proc = subprocess.Popen(
        [binary, "-C", work, "--yolo", "--set", "plugins.onboarding.plugins=false", *args],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=dict(os.environ, TERM="xterm-256color"),
        start_new_session=True,
    )
    os.close(slave)
    raw = bytearray()

    def until(needle):
        deadline = time.monotonic() + 20
        while needle not in ansi.sub("", raw.decode("utf-8", "replace")):
            assert time.monotonic() < deadline, raw.decode("utf-8", "replace")[-5000:]
            assert proc.poll() is None, "terminal exited early"
            if select.select([master], [], [], 0.1)[0]:
                chunk = os.read(master, 65536)
                raw.extend(chunk)
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")

    def plain():
        return ansi.sub("", raw.decode("utf-8", "replace"))

    def send(value):
        raw.clear()
        seen_busy = plain().count("startup is still in progress")
        os.write(master, value.encode() + b"\r")
        # On startup / resume, submitting before init completes shows "startup is still in progress".
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.5)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                raw.extend(chunk)
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")
                txt = plain()
                count = txt.count("startup is still in progress")
                if count > seen_busy:
                    seen_busy = count
                    time.sleep(0.5)
                    os.write(master, b"\r")
                    continue
            else:
                break

    def wait_result(predicate):
        deadline = time.monotonic() + 10
        result = Path(os.environ["TITLE_RESULT"])
        while True:
            if result.exists():
                try:
                    state = json.loads(result.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    state = None
                if state and predicate(state):
                    return state
            assert time.monotonic() < deadline, "title result gate timed out"
            assert proc.poll() is None, "terminal exited early"
            if select.select([master], [], [], 0.05)[0]:
                chunk = os.read(master, 65536)
                raw.extend(chunk)
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")

    try:
        until("Ask mare anything")
        if not restored:
            send("implement terminal title")
            until("Stable parser title")
            state = wait_result(
                lambda s: (s.get("metadata") or {}).get("source") == "provider"
            )
            send("/title")
            until(state["name"])
            send("/title rename Terminal pinned title")
            wait_result(lambda s: s.get("name") == "Terminal pinned title")
        send("/title")
        until("Terminal pinned title")
        send("/exit")
        exit_deadline = time.monotonic() + 10
        while proc.poll() is None:
            if time.monotonic() >= exit_deadline:
                os.write(master, b"\x03")
                time.sleep(0.2)
                os.write(master, b"\x03")
                break
            if select.select([master], [], [], 0.1)[0]:
                try:
                    raw.extend(os.read(master, 65536))
                except OSError:
                    break
        drain_deadline = time.monotonic() + 10
        while proc.poll() is None and time.monotonic() < drain_deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    raw.extend(os.read(master, 65536))
                except OSError:
                    break
        assert proc.wait(timeout=10) == 0, plain()[-5000:]
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        os.close(master)


run("--session-id", "title-tui")
run("--resume", "title-tui", restored=True)
print("session-title real TUI generated title, manual rename and resume passed")
