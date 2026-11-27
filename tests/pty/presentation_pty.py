#!/usr/bin/env python3
"""Native PTY probe -> assistant fence -> actual PNG graphics; late updates, replay and cancel.

The PTY emulates XTVERSION/DA replies. No Lua mode/caps/connected overrides are installed.
This validates real terminal protocol output, not a physical terminal screenshot.
"""

import base64
import fcntl
import json
import os
import re
import signal
import struct
import sys
import termios
import zlib

import pty_cleanup as cleanup
from presentation_client import write_presenter
from pty_terminal import Tty, plain


class Terminal(Tty):
    def __init__(self, binary, args, home, script, images=True):
        self.version_answered, self.images = False, images
        super().__init__(
            binary,
            ["--yolo", *args],
            False,
            {
                "MARE_HOME": home,
                "MARE_FAUX_SCRIPT": script,
                "TERM_PROGRAM": "mare-test-pty",
                "PRESENTATION_CAPS_REPORT": os.path.join(home, "caps.json"),
                "PRESENTATION_SESSION_REPORT": os.path.join(home, "session.json"),
            },
        )
        # This emulator answers the entire native probe in order, with DA1 last. The base
        # helper's earlier DA1 reply would fence out a following XTVERSION response.
        self.answered = True

    def _read(self, timeout):
        chunk = super()._read(timeout)
        if (
            not self.version_answered
            and b"\x1b[c" in self.out
            and b"\x1b[>q" in self.out
        ):
            self.version_answered = b"\x1b[>q" in self.out
            version = b"kitty(0.40.0)" if self.images else b"plain-test-terminal(1.0)"
            os.write(
                self.master,
                b"\x1bP>|" + version + b"\x1b\\\x1b[6;16;8t\x1b[3;1R\x1b[?62;22c",
            )
        return chunk


def image_records(raw):
    payloads, pending = [], None
    for match in re.finditer(rb"\x1b_G([^;\x1b]+);([A-Za-z0-9+/=]*)\x1b\\", raw):
        options, data = match.groups()
        if b"a=T" in options:
            pending = data
            fields = dict(
                field.split(b"=", 1) for field in options.split(b",") if b"=" in field
            )
            identity = (int(fields[b"i"]), int(fields.get(b"p", b"0")))
            prefix = raw[: match.start()].rsplit(b"\r", 1)[-1]
            offset = sum(int(value) for value in re.findall(rb"\x1b\[(\d+)C", prefix))
        elif pending is not None and options.startswith(b"m="):
            pending += data
        else:
            continue
        if b"m=1" not in options:
            value = base64.b64decode(pending, validate=True)
            assert value[:8] == b"\x89PNG\r\n\x1a\n"
            position, packed = 8, bytearray()
            width = height = None
            while position < len(value):
                length = struct.unpack(">I", value[position : position + 4])[0]
                kind, body = (
                    value[position + 4 : position + 8],
                    value[position + 8 : position + 8 + length],
                )
                expected = struct.unpack(
                    ">I", value[position + 8 + length : position + 12 + length]
                )[0]
                assert zlib.crc32(kind + body) == expected
                if kind == b"IHDR":
                    width, height = struct.unpack(">II", body[:8])
                if kind == b"IDAT":
                    packed.extend(body)
                position += length + 12
            assert width and height and zlib.decompress(packed)
            payloads.append(
                {
                    "size": (width, height),
                    "identity": identity,
                    "offset": offset,
                    "png": value,
                }
            )
            pending = None
    return payloads


def images(raw):
    return [record["size"] for record in image_records(raw)]


def trace(name, terminal):
    directory = os.environ.get("PRESENTATION_TRACE_DIR")
    if directory:
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, name + ".ansi"), "wb") as stream:
            stream.write(terminal.out)


def setup(steps):
    home = cleanup.directory(prefix="mare-presentation-")
    write_presenter(home)
    path = os.path.join(home, "faux.json")
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(steps, stream)
    return home, path


def assert_capabilities(terminal, home, expected):
    with open(os.path.join(home, "caps.json"), encoding="utf-8") as stream:
        report = json.load(stream)
    assert terminal.version_answered, (
        f"native XTVERSION probe was not answered: {terminal.out[:1200]!r} {report}"
    )
    assert report["mode"] == "tui" and report["caps"]["images"] == expected, report


@cleanup.scoped
def late_replay_resize(binary):
    home, script = setup(
        [
            {
                "text": "before\n\n> ```drawing\n> slow\n> ```\n\n- list\n\n  > ```drawing\n  > slow\n  > ```\n\nafter"
            }
        ]
    )
    terminal = Terminal(binary, [], home, script)
    terminal.ready()
    assert_capabilities(terminal, home, "kitty")
    # The source finishes before the 200ms presenter. No resize or further model token is
    # needed for the late component to reach actual native graphics output.
    terminal.submit(
        b"render a diagram",
        until=lambda raw: len({r["identity"] for r in image_records(raw)}) >= 2,
    )
    records = image_records(terminal.out)
    assert len({record["identity"] for record in records}) >= 2, plain(terminal.out)[
        -1500:
    ]
    assert {4, 6}.issubset({record["offset"] for record in records}), records
    assert len({record["png"] for record in records}) == 1, (
        "same PNG data must remain unchanged across occurrences"
    )
    assert "before" in plain(terminal.out) and "after" in plain(terminal.out)
    with open(os.path.join(home, "session.json"), encoding="utf-8") as stream:
        session = json.load(stream)
    trace("late-identical-png", terminal)
    terminal.quit()
    resumed = Terminal(binary, ["--resume", session["path"]], home, script)
    resumed.ready()
    if "recorded in another directory" in plain(resumed.out):
        # A real user chooses the current directory in the public resume dialog.
        os.write(resumed.master, b"\x1b[B\r")
    resumed.pump(10, until=lambda raw: bool(images(raw)))
    assert images(resumed.out), plain(resumed.out)[-1500:]
    mark = len(resumed.out)
    fcntl.ioctl(resumed.master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 40, 0, 0))
    os.kill(resumed.p.pid, signal.SIGWINCH)
    resumed.pump(
        10, until=lambda raw: b"viewport:40" in raw[mark:] and bool(images(raw[mark:]))
    )
    assert b"viewport:40" in resumed.out[mark:] and images(resumed.out[mark:])
    assert resumed.p.poll() is None
    trace("resume-narrow", resumed)
    resumed.quit()


@cleanup.scoped
def cancelled_and_no_images(binary):
    body = "```drawing\nslow-cancel\n```\n\nCANCEL-TAIL " + "pending " * 40
    home, script = setup(
        [{"text": body, "delay_ms": 30}, {"text": "```drawing\nnew generation\n```"}]
    )
    terminal = Terminal(binary, ["--no-session"], home, script)
    terminal.ready()
    assert_capabilities(terminal, home, "kitty")
    terminal.submit(b"cancel diagram", until=lambda raw: b"CANCEL-TAIL" in raw)
    os.write(terminal.master, b"\x03")
    terminal.pump(2, until=lambda raw: "Interrupted" in plain(raw))
    terminal.settle(0.4)
    assert not images(terminal.out), "cancelled occurrence produced late image bytes"
    trace("cancelled-before-next", terminal)
    terminal.submit(b"next", until=lambda raw: bool(images(raw)))
    assert images(terminal.out), plain(terminal.out)[-1000:]
    assert all(width >= height for width, height in images(terminal.out)), (
        "stale cancelled variant leaked"
    )
    terminal.quit()
    home, script = setup([{"text": "```drawing\nslow\ncomplete source\n```"}])
    plain_terminal = Terminal(binary, ["--no-session"], home, script, images=False)
    plain_terminal.ready()
    assert_capabilities(plain_terminal, home, "none")
    plain_terminal.submit(b"source", until=lambda raw: b"complete source" in raw)
    plain_terminal.settle(0.4)
    assert not images(plain_terminal.out)
    assert "slow" in plain(plain_terminal.out) and "complete source" in plain(
        plain_terminal.out
    )
    trace("no-image-source", plain_terminal)
    plain_terminal.quit()


@cleanup.scoped
def partial_stream_and_old_generation(binary):
    body = "lead\n\n```drawing\nslow\n```\n\n" + "tail " * 150 + "PARTIAL-DONE"
    home, script = setup([{"text": body, "delay_ms": 8}])
    terminal = Terminal(binary, ["--no-session"], home, script)
    terminal.ready()
    terminal.submit(b"stream", until=lambda raw: bool(images(raw)))
    assert images(terminal.out) and "PARTIAL-DONE" not in plain(terminal.out), (
        "image must replace a partially committed stream"
    )
    terminal.pump(10, until=lambda raw: b"PARTIAL-DONE" in raw)
    terminal.settle(0.2)
    assert "PARTIAL-DONE" in plain(terminal.out)
    assert len({record["identity"] for record in image_records(terminal.out)}) == 1, (
        "identity must survive stream updates"
    )
    trace("partial-to-finish", terminal)
    terminal.quit()
    home, script = setup(
        [
            {"text": "```drawing\nslow-cancel\n```\n\nAFTER-GEN"},
            {"text": "```drawing\nnew scope\n```"},
        ]
    )
    terminal = Terminal(binary, ["--no-session"], home, script)
    terminal.ready()
    terminal.submit(b"old scope", until=lambda raw: b"AFTER-GEN" in raw)
    terminal.settle(0.05)
    os.write(terminal.master, b"/new\r")
    terminal.pump(2, until=lambda raw: b"New session" in raw)
    terminal.settle(0.35)
    assert not images(terminal.out), "old generation emitted a late graph"
    trace("old-generation-rejected", terminal)
    terminal.submit(b"new scope", until=lambda raw: bool(images(raw)))
    assert images(terminal.out) and all(
        width >= height for width, height in images(terminal.out)
    )
    terminal.quit()


def main():
    # The test process owns these env values; use only the native probe for graphic capability.
    for name in (
        "KITTY_WINDOW_ID",
        "GHOSTTY_RESOURCES_DIR",
        "WEZTERM_PANE",
        "WARP_SESSION_ID",
        "ITERM_SESSION_ID",
        "ZELLIJ",
    ):
        os.environ.pop(name, None)
    binary = os.path.abspath(sys.argv[1])
    late_replay_resize(binary)
    cancelled_and_no_images(binary)
    partial_stream_and_old_generation(binary)
    print(
        "presentation_pty: native probe/PNG, late commit, replay, narrow resize, cancel and no-image source passed"
    )


if __name__ == "__main__":
    main()
