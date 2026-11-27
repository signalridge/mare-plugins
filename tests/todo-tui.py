"""Real terminal history, checklist commands, cancellation and read-only recovery."""

import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import codecs
import fcntl
import json
import pty
import re
import select
import struct
import subprocess
import termios
import time
import unicodedata
from pathlib import Path

binary, work, script = sys.argv[1:]
Path(script).write_text(
    json.dumps(
        [
            {
                "tool_calls": [
                    {
                        "name": "todo_write",
                        "arguments": {
                            "explanation": "Reason for checklist update",
                            "todos": [
                                {
                                    "content": "visible terminal step",
                                    "status": "in_progress",
                                },
                                {"content": "later terminal step", "status": "pending"},
                            ],
                        },
                    }
                ]
            },
            {"text": "todo-tui-finished"},
        ]
    ),
    encoding="utf-8",
)
ansi = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")


class ScreenBuffer:
    """Minimal VT100/ANSI screen tracker so ratatui differential cell updates stay visible."""

    def __init__(self, rows, cols):
        self.rows = rows
        self.cols = cols
        self.row = 0
        self.col = 0
        self.grid = [[" "] * cols for _ in range(rows)]
        self._buf = ""
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def resize(self, rows, cols):
        self.rows = rows
        self.cols = cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.row = min(self.row, rows - 1)
        self.col = min(self.col, cols - 1)

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.grid)

    def feed(self, chunk):
        self._buf += self._decoder.decode(chunk)
        s = self._buf
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    break
                nxt = s[i + 1]
                if nxt == "[":
                    j = i + 2
                    while j < n and not ("@" <= s[j] <= "~"):
                        j += 1
                    if j >= n:
                        break
                    self._csi(s[i + 2 : j], s[j])
                    i = j + 1
                elif nxt == "]":
                    bel = s.find("\x07", i + 2)
                    st = s.find("\x1b\\", i + 2)
                    if bel == -1 and st == -1:
                        break
                    if bel != -1 and (st == -1 or bel < st):
                        i = bel + 1
                    else:
                        i = st + 2
                else:
                    i += 2
            elif ch == "\r":
                self.col = 0
                i += 1
            elif ch == "\n":
                if self.row + 1 < self.rows:
                    self.row += 1
                else:
                    self.grid.pop(0)
                    self.grid.append([" "] * self.cols)
                self.col = 0
                i += 1
            elif ch == "\b":
                self.col = max(0, self.col - 1)
                i += 1
            elif ord(ch) >= 32:
                if unicodedata.combining(ch):
                    i += 1
                    continue
                w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
                if self.col >= self.cols:
                    self.col = self.cols - 1
                self.grid[self.row][self.col] = ch
                if w == 2 and self.col + 1 < self.cols:
                    self.grid[self.row][self.col + 1] = ""
                self.col = min(self.cols - 1, self.col + w)
                i += 1
            else:
                i += 1
        self._buf = s[i:]

    def _csi(self, params, cmd):
        if params.startswith(("?", ">", "=")):
            return
        parts = [int(p) if p else 0 for p in params.split(";")] if params else [0]
        p1 = parts[0]
        if cmd in ("H", "f"):
            r = (parts[0] if len(parts) >= 1 and parts[0] > 0 else 1) - 1
            c = (parts[1] if len(parts) >= 2 and parts[1] > 0 else 1) - 1
            self.row = max(0, min(self.rows - 1, r))
            self.col = max(0, min(self.cols - 1, c))
        elif cmd == "A":
            self.row = max(0, self.row - max(1, p1))
        elif cmd == "B":
            self.row = min(self.rows - 1, self.row + max(1, p1))
        elif cmd == "C":
            self.col = min(self.cols - 1, self.col + max(1, p1))
        elif cmd == "D":
            self.col = max(0, self.col - max(1, p1))
        elif cmd == "G":
            self.col = max(0, min(self.cols - 1, max(1, p1) - 1))
        elif cmd == "d":
            self.row = max(0, min(self.rows - 1, max(1, p1) - 1))
        elif cmd == "J":
            if p1 == 0:
                self.grid[self.row][self.col :] = [" "] * (self.cols - self.col)
                for r in range(self.row + 1, self.rows):
                    self.grid[r] = [" "] * self.cols
            elif p1 == 1:
                for r in range(self.row):
                    self.grid[r] = [" "] * self.cols
                self.grid[self.row][: self.col + 1] = [" "] * (self.col + 1)
            elif p1 in (2, 3):
                self.grid = [[" "] * self.cols for _ in range(self.rows)]
        elif cmd == "K":
            if p1 == 0:
                self.grid[self.row][self.col :] = [" "] * (self.cols - self.col)
            elif p1 == 1:
                self.grid[self.row][: self.col + 1] = [" "] * (self.col + 1)
            elif p1 == 2:
                self.grid[self.row] = [" "] * self.cols


class Terminal:
    def __init__(self, *args, env=None):
        self.master, slave = pty.openpty()
        self.screen = ScreenBuffer(28, 90)
        self.resize(28, 90)
        self.p = subprocess.Popen(
            [binary, "-C", work, "--yolo", "--set", "plugins.onboarding.plugins=false", *args],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=dict(os.environ, TERM="xterm-256color", **(env or {})),
            start_new_session=True,
        )
        os.close(slave)
        self.raw = bytearray()

    def resize(self, rows, columns):
        fcntl.ioctl(
            self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0)
        )
        self.screen.resize(rows, columns)

    def text(self):
        return ansi.sub("", self.raw.decode("utf-8", "replace"))

    def screen_text(self):
        return self.screen.text()

    def send(self, value):
        self.raw.clear()
        os.write(self.master, value)

    def until(self, needle, timeout=15):
        end = time.monotonic() + timeout
        while needle not in self.text():
            assert time.monotonic() < end, (
                f"TUI did not show {needle!r}:\n--- screen ---\n{self.screen_text()}\n--- raw ---\n{self.text()[-6000:]}"
            )
            self._pump(end)

    def until_screen(self, needle_or_pred, timeout=15):
        pred = (
            needle_or_pred
            if callable(needle_or_pred)
            else (lambda s: needle_or_pred in s)
        )
        end = time.monotonic() + timeout
        while not pred(self.screen_text()):
            assert time.monotonic() < end, (
                f"TUI screen did not satisfy condition:\n--- screen ---\n{self.screen_text()}\n--- raw ---\n{self.text()[-6000:]}"
            )
            self._pump(end)

    def _pump(self, end):
        ready, _, _ = select.select([self.master], [], [], 0.1)
        if ready:
            chunk = os.read(self.master, 65536)
            self.raw.extend(chunk)
            self.screen.feed(chunk)
            if b"\x1b[6n" in chunk:
                os.write(self.master, b"\x1b[1;1R")
        assert self.p.poll() is None, self.text()[-6000:]

    def close(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        os.close(self.master)


owner = Terminal("--session-id", "todo-tui", "track terminal work")
reader = None
try:
    owner.until("todo-tui-finished")
    for text in ("Updated todos", "Reason for checklist update", "2 added"):
        owner.until(text)
    owner.send(b"/todos expand\r")
    owner.until("[~] visible terminal step")
    owner.send(b"/todos\r")
    owner.until("Esc cancel")
    assert "visible terminal step" in owner.text() and "Preview" in owner.text()
    owner.send(b"\x1b")
    owner.until_screen(lambda s: "Esc cancel" not in s and "Ask mare" in s)
    owner.send(b"/todos collapse\r")
    owner.until_screen("▸ Todos")
    assert "[~] visible terminal step" not in owner.screen_text(), owner.screen_text()
    owner.resize(18, 32)
    owner.send(b"/todos\r")
    owner.until("Esc cancel")
    owner.send(b"\x1b")
    owner.until_screen(lambda s: "Esc cancel" not in s and "Ask mare" in s)

    # The actual interactive recovery offers fork/read-only while owner holds the lock.
    reader = Terminal("--resume", "todo-tui")
    reader.until("View read-only")
    reader.send(b"\x1b[B\r")
    reader.until("read-only view")
    reader.until("▸ Todos")
    # The first frame is intentionally interactive before startup accepts input.
    time.sleep(0.25)
    reader.send(b"/todos\r")
    reader.until("visible terminal step")
    reader.until("Esc cancel")
    reader.send(b"\x1b")
    reader.until_screen(lambda s: "Esc cancel" not in s and "Ask mare" in s)
    reader.send(b"new task must not mutate the checklist\r")
    reader.until("todo-tui-finished")
    # Read-only turns clear the ephemeral view without mutating the owner's persisted checklist.
    reader.send(b"/todos\r")
    reader.until("No checklist has been written for this work")
    reader.until("Esc cancel")
    reader.send(b"\x1b")
    reader.until_screen(lambda s: "Esc cancel" not in s and "Ask mare" in s)
    owner.send(b"/todos\r")
    owner.until("visible terminal step")
    owner.until("Esc cancel")
    print(
        "todo: terminal history/diff, viewer cancellation, resize and real read-only recovery passed"
    )
finally:
    if reader:
        reader.close()
    owner.close()

# Archive an older tool result through public agent:append, then replay it in the
# actual terminal. No private store module or hand-written JSONL is involved.
Path(script).write_text(json.dumps([{"text": "legacy seed finished"}]), encoding="utf-8")
seed = subprocess.run(
    [binary, "-C", work, "--yolo", "-p", "--session-id", "todo-legacy", "Finish seed"],
    env=dict(os.environ, TODO_LEGACY_SEED="1"),
    check=False,
    capture_output=True,
    text=True,
    timeout=20,
    encoding="utf-8",
)
assert seed.returncode == 0, (seed.stdout, seed.stderr)
legacy = Terminal("--resume", "todo-legacy")
try:
    legacy.until("Baseline unavailable")
    assert "legacy result without details" in legacy.text(), legacy.text()
finally:
    legacy.close()

Path(script).write_text(
    json.dumps(
        [
            {
                "tool_calls": [
                    {
                        "name": "todo_write",
                        "arguments": {
                            "todos": [{"content": " ", "status": "completed"}]
                        },
                    }
                ]
            },
            {"text": "todo-error-ui-finished"},
        ]
    ),
    encoding="utf-8",
)
failed = Terminal("--session-id", "todo-error-ui", "Reject an invalid checklist")
try:
    failed.until("todo-error-ui-finished")
    failed.until("Todo update failed")
    assert "Updated todos" not in failed.text(), failed.text()
finally:
    failed.close()
print(
    "todo: legacy result replay and failed update card never presented as success passed"
)

Path(script).write_text(
    json.dumps(
        [
            {
                "tool_calls": [
                    {
                        "name": "todo_write",
                        "arguments": {
                            "todos": [
                                {
                                    "content": "must not commit after Esc",
                                    "status": "completed",
                                }
                            ]
                        },
                    }
                ]
            },
            {"text": "todo-cancel-ui-finished"},
        ]
    ),
    encoding="utf-8",
)
cancelled = Terminal(
    "--session-id",
    "todo-cancel-ui",
    "Cancel the checklist approval",
    env={"TODO_CANCEL_APPROVAL": "1"},
)
try:
    cancelled.until("Allow once")
    cancelled.send(b"\x1b")
    cancelled.until("todo-cancel-ui-finished")
    assert "Updated todos" not in cancelled.text(), cancelled.text()
    final_request = json.loads(
        Path(script).with_name("requests.jsonl").read_text(encoding="utf-8").splitlines()[-1]
    )
    denied = [
        m
        for m in final_request["messages"]
        if m.get("role") == "tool_result" and m.get("tool_name") == "todo_write"
    ]
    assert denied and denied[-1].get("is_error") is True, denied
    assert "denied" in json.dumps(denied[-1]).lower(), denied[-1]
    cancelled.send(b"/todos\r")
    cancelled.until("No checklist has been written")
finally:
    cancelled.close()
print("todo: real approval Esc leaves no checklist and no successful update card")
