#!/usr/bin/env python3
"""Terminal behaviour on a real pseudo-terminal.

usage: pty_terminal.py path/to/mare

1. kitty keyboard is query-first: when the "terminal" answers `CSI ? u`, mare pushes its flags
   after the answer and pops exactly that one entry on exit; when it doesn't answer, mare never
   pushes or pops;
2. an idle TUI writes nothing (no change → zero bytes; no timed redraw without animation);
3. hostile tool output (OSC 52 clipboard, OSC 0 title, screen clear) never reaches the
   terminal; its text is still shown;
4. every write path goes through the write exit's final check: frames (an in-TUI notice), the
   window title (OSC 2) and desktop notifications (OSC 9) carry hostile plugin text only as
   cleaned text; modes and the startup probe are covered by (1);
5. a resize (SIGWINCH) redraws at the new width and the TUI keeps running, although stdout is
   captured (termina reads the size from fd 1; mare asks the saved terminal fd).
"""

import fcntl
import json
import os
import re
import select
import sys
import termios
import threading
import time

import pty_cleanup as cleanup

INPUT_BOX = "╰".encode()
# Ceilings for event waits: every wait ends the moment its event happens, so a healthy run never
# reaches them; they only catch a hang. 100 s is ~30x the slowest idle wait, and stays under
# nextest's default 120 s kill (a larger ceiling could never report its own message).
BOOT = 100
STEP = 2
# mare's refusal of a prompt submitted while startup (config, packages, MCP) is still running; the
# text stays in the input box and the notice says to press Enter again once it is ready
NOT_READY = "startup is still in progress"
NOTICE_LIFE = 6  # app.rs NOTICE_LIFE: how long a notification card stays


def plain(raw):
    """Printable text of terminal output (escape sequences dropped), for failure messages."""
    return re.sub(rb"\x1b\[[0-9;?<>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", b"", raw).decode("utf-8", "replace")


class Tty:
    def __init__(self, binary, args, answer_kitty, env_extra=None):
        self.home = cleanup.directory(prefix="mare-ptyt-")
        self.work = cleanup.directory(prefix="mare-ptyt-cwd-")
        self.master, slave = os.openpty()
        cleanup.descriptor(self.master)
        fcntl.ioctl(
            slave, termios.TIOCSWINSZ, b"\x1e\x00\x64\x00\x00\x00\x00\x00"
        )  # 30x100
        self.answer_kitty = answer_kitty
        self.answered = False
        self.out = b""

        def ctty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        env = dict(os.environ, MARE_HOME=self.home, TERM="xterm-256color")
        env.update(env_extra or {})
        env.pop("TMUX", None)
        launch_args = list(args)
        if not any("onboarding.plugins" in str(a) for a in launch_args):
            launch_args.extend(["--set", "plugins.onboarding.plugins=false"])
        self.p = cleanup.spawn(
            slave,
            [binary, "--model", "faux/echo", *launch_args],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            cwd=self.work,
            env=env,
            preexec_fn=ctty,
            close_fds=True,
        )

    def _read(self, timeout):
        """One select+read: the bytes, b"" for nothing yet, None at EOF; answers the startup
        probe like a terminal would."""
        r, _, _ = select.select([self.master], [], [], timeout)
        if not r:
            return b""
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            if self.p.poll() is not None:
                return None  # mare is gone and the pty is drained
            time.sleep(0.02)  # EIO / EOF while mare lives: nothing to read yet
            return b""
        self.out += chunk
        if not self.answered and b"\x1b[6n" in self.out:
            self.answered = True
            reply = (b"\x1b[?1u" if self.answer_kitty else b"") + b"\x1b[3;1R\x1b[?62;22c"
            os.write(self.master, reply)
        return chunk

    def pump(self, secs, until=None, until_exit=False):
        """Read output for up to `secs` (a ceiling, not a wait: `until` or `until_exit` ends it
        as soon as the event happens)."""
        got = b""
        end = time.monotonic() + secs
        if until and until(self.out):
            return got  # the event already happened (an earlier pump read past it)
        while time.monotonic() < end:
            chunk = self._read(0.05)
            if chunk is None:
                break
            if not chunk:
                if until_exit and self.p.poll() is not None:
                    break  # exited and the pty is drained
                continue
            got += chunk
            if until and until(self.out):
                break
        return got

    def raw(self):
        """mare has put the terminal into raw mode: from here typed bytes reach its input
        reader instead of the line discipline (which would eat or echo them)."""
        try:
            return not (termios.tcgetattr(self.master)[3] & termios.ICANON)
        except termios.error:
            return False

    def ready(self):
        """The TUI is up and reads keys: the input box is drawn and the terminal is raw, then
        the startup output has stopped."""
        deadline = time.monotonic() + BOOT
        self.pump(BOOT, until=lambda b: INPUT_BOX in b)
        while not self.raw() and time.monotonic() < deadline:
            self.pump(0.05)
        self.settle(0.5)

    def settle(self, quiet, ceiling=BOOT):
        """Read until the terminal has been silent for `quiet` seconds (startup is over when
        the output stops, however long a loaded box takes to get there)."""
        got = b""
        deadline = time.monotonic() + ceiling
        last = time.monotonic()
        while time.monotonic() < deadline and time.monotonic() - last < quiet:
            chunk = self._read(0.05)
            if chunk is None:
                break
            if chunk:
                got += chunk
                last = time.monotonic()
        return got

    def submit(self, text, until):
        """Type `text` + Enter and wait (BOOT ceiling) until `until(self.out)`. `ready()` cannot
        tell that startup is over, so on a loaded box mare may refuse the prompt as "startup is
        still in progress"; as that notice tells a user, press Enter again once it is ready."""

        def refusals():
            return plain(self.out).count(NOT_READY)

        seen = refusals()
        os.write(self.master, text + b"\r")
        deadline = time.monotonic() + BOOT
        while not until(self.out) and time.monotonic() < deadline:
            self.pump(0.5, until=lambda b: until(b) or refusals() > seen)
            if not until(self.out) and refusals() > seen:
                seen = refusals()
                self.settle(0.5)
                os.write(self.master, b"\r")
        return self.out

    def quit(self):
        def send(keys):
            # mare may have exited already: writing to a closed pty is EIO, not a failure
            if self.p.poll() is None:
                try:
                    os.write(self.master, keys)
                except OSError:
                    pass

        # Ctrl-D exits an idle empty prompt (it never exits while a turn is still ending). Then
        # Ctrl-C: it interrupts work, clears a draft, and two presses within the 2 s quit window
        # exit; sent every 0.5 s so any state reaches that second press. Each wait ends the
        # moment mare exits (the ceiling only matters when mare is stuck), then the pty drains.
        tail = b""
        send(b"\x04")
        tail += self.pump(STEP, until_exit=True)
        deadline = time.monotonic() + BOOT
        while self.p.poll() is None and time.monotonic() < deadline:
            send(b"\x03")
            tail += self.pump(0.5, until_exit=True)
        self.p.wait(timeout=BOOT)
        tail += self.pump(1.0, until_exit=True)
        return tail


# mare's terminal probe has a hard 100 ms deadline (app/term/caps.rs read_probe): a
# "terminal" that a starved box schedules later than that answers too late, and mare then rightly
# never pushes kitty flags. That is the probe's own latency bound, not something a longer wait can
# fix, so an answered probe that produced no push is retried on a fresh instance; a real
# regression (never pushing) fails every try.
KITTY_TRIES = 6


@cleanup.scoped
def kitty_query_first(binary):
    for answer in (True, False):
        for attempt in range(KITTY_TRIES):
            t = Tty(binary, [], answer)
            t.pump(BOOT, until=lambda b: INPUT_BOX in b)
            assert INPUT_BOX in t.out, f"no input box: {t.out[-300:]!r}"
            if not answer:
                break
            t.pump(10, until=lambda b: b"\x1b[>1u" in b)  # the push follows the answer
            if b"\x1b[>1u" in t.out or attempt + 1 == KITTY_TRIES:
                break
            t.quit()  # the answer missed the probe's deadline: start over
        t.settle(1.0)  # probe answered, kitty decision made (an unanswered probe pushes nothing)
        before_quit = t.out
        tail = t.quit()
        q = before_quit.find(b"\x1b[6n")
        if answer:
            push = before_quit.find(b"\x1b[>1u")
            assert push > q >= 0, (
                f"kitty must be pushed after the probe answer: {before_quit[-600:]!r}"
            )
            assert before_quit.count(b"\x1b[>1u") == 1, "pushed once"
            assert tail.count(b"\x1b[<1u") == 1, f"popped exactly once: {tail[-300:]!r}"
        else:
            assert b"\x1b[>1u" not in t.out, "no answer: never push"
            assert b"\x1b[<" not in tail, "never pop an entry we didn't push"


@cleanup.scoped
def idle_writes_nothing(binary):
    t = Tty(binary, [], False)
    t.pump(BOOT, until=lambda b: INPUT_BOX in b)
    # The startup permissions card disappears on its own NOTICE_LIFE (6 s) after it appears: that
    # redraw is the product's one timed write, not idleness. Wait it out from the moment the card
    # is known to be on screen (never earlier than its creation), then require silence.
    t.pump(BOOT, until=lambda b: b"Permissions" in b)
    t.pump(NOTICE_LIFE + 1, until=lambda b: False)
    # probe, welcome, ui/ready, the card's removal are all behind us: a starved mare can write the
    # removal well after its 6 s, so require a long silence before the idle window starts
    t.settle(3.0)
    idle = t.pump(2.0)
    t.quit()
    assert idle == b"", f"an idle TUI wrote {len(idle)} bytes: {idle[:200]!r}"


@cleanup.scoped
def resize_redraws_at_the_new_width(binary):
    t = Tty(binary, [], False)
    t.pump(BOOT, until=lambda b: INPUT_BOX in b)
    # let the startup card go first (see idle_writes_nothing): its removal is a redraw at the old
    # width that a starved mare can write after the resize mark
    t.pump(BOOT, until=lambda b: b"Permissions" in b)
    t.pump(NOTICE_LIFE + 1, until=lambda b: False)
    t.settle(3.0)
    # 30 rows x 80 columns: the kernel sends SIGWINCH to the foreground process group
    mark = len(t.out)
    fcntl.ioctl(t.master, termios.TIOCSWINSZ, b"\x1e\x00\x50\x00\x00\x00\x00\x00")
    # the redraw is the event: the first complete input box after the resize
    t.pump(BOOT, until=lambda b: re.search("╰(?:─)+╯".encode(), b[mark:]) is not None)
    t.settle(0.5)
    after = t.out[mark:]
    assert t.p.poll() is None, f"mare exited on a resize: {after[-400:]!r}"
    widths = [len(m) for m in re.findall("╰─+╯", after.decode("utf-8", "replace"))]
    assert widths and max(widths) <= 80, f"input box not redrawn within 80 columns: {widths}"
    t.quit()


@cleanup.scoped
def hostile_output_is_filtered(binary):
    script = os.path.join(cleanup.directory(prefix="mare-ptyt-faux-"), "faux.json")
    hostile = (
        r"printf '\033]52;c;ZXZpbA==\007\033]0;pwned\007\033[2J\033[1;1HVISIBLE-TEXT\n'"
    )
    with open(script, "w", encoding="utf-8") as f:
        json.dump(
            [
                {"tool_calls": [{"name": "bash", "arguments": {"command": hostile}}]},
                {"text": "all done"},
            ],
            f,
        )
    t = Tty(binary, ["--yolo"], False, {"MARE_FAUX_SCRIPT": script})
    t0 = time.monotonic()
    t.ready()
    t1 = time.monotonic()
    t.submit(b"go", lambda b: b"all done" in b)
    t2 = time.monotonic()
    screen = plain(t.out)
    t.quit()
    out = t.out
    assert b"all done" in out, (
        f"turn didn't finish (ready took {t1 - t0:.1f}s, waited {t2 - t1:.1f}s; tool text shown: "
        f"{b'VISIBLE-TEXT' in out}): {screen[-1500:]!r}"
    )
    assert b"VISIBLE-TEXT" in out, "the text itself is still shown"
    assert b"\x1b]52" not in out, "clipboard write reached the terminal"
    assert (
        b"pwned" not in out.split(b"VISIBLE-TEXT")[0] or b"\x1b]0;pwned" not in out
    ), "title changed"
    assert b"\x1b]0;pwned" not in out and b"\x1b]2;pwned" not in out, "title changed"
    assert b"\x1b[2J" not in out, "screen cleared by tool output"


@cleanup.scoped
def extension_points(binary):
    """ui/commit:before can append to committed lines; ui/caps can override capabilities."""
    t = Tty.__new__(Tty)
    home = cleanup.directory(prefix="mare-ptyt-ext-")
    os.makedirs(os.path.join(home, "config"), exist_ok=True)
    with open(os.path.join(home, "config", "init.lua"), "w", encoding="utf-8") as f:
        f.write(
            'mare.on("ui/commit:before", function(e) e.lines[#e.lines + 1] = "HOOKED-LINE"; return e end)\n'
            'mare.on("ui/caps", function(c, next) c.sync = false; return next(c) end)\n'
        )
    Tty.__init__(t, binary, [], False, {"MARE_HOME": home})
    t.ready()
    # the welcome banner is a commit too (it carries the hook's line): let it come first, so
    # the line this test waits for can only be the one of the "hello" turn
    t.pump(BOOT, until=lambda b: b"HOOKED-LINE" in b)
    t.settle(0.5)
    mark = len(t.out)
    t.submit(b"hello", lambda b: b"HOOKED-LINE" in b[mark:])
    t.settle(0.3)
    t.quit()
    after = t.out[mark:]
    assert b"HOOKED-LINE" in after, (
        f"commit hook output missing (exit {t.p.poll()}): {plain(t.out)[-1500:]!r}"
    )
    assert b"\x1b[?2026h" not in after, "ui/caps set sync = false: no synchronized-output brackets"


@cleanup.scoped
def write_paths_are_filtered(binary):
    t = Tty.__new__(Tty)
    home = cleanup.directory(prefix="mare-ptyt-wp-")
    os.makedirs(os.path.join(home, "config"), exist_ok=True)
    evil = r"\27]52;c;ZXZpbA==\7\27[2J\27]2;pwned\7"
    with open(os.path.join(home, "config", "init.lua"), "w", encoding="utf-8") as f:
        f.write(
            'mare.on("ui/ready", function()\n'
            f'  mare.ui.set_title("TITLE-{evil}-END")\n'
            f'  mare.ui.notify_os("NOTE-{evil}-END", {{ protocol = "osc9" }})\n'
            f'  mare.ui.notify("FRAME-{evil}-END")\n'
            "end)\n"
        )
    Tty.__init__(t, binary, [], False, {"MARE_HOME": home})
    t.pump(BOOT, until=lambda b: INPUT_BOX in b)
    t.pump(BOOT, until=lambda b: b"FRAME-" in b and b"\x1b]9;" in b)
    t.settle(0.3)
    t.quit()
    out = t.out
    assert b"\x1b]2;" in out and b"TITLE-" in out, f"title not written: {out[-400:]!r}"
    assert b"\x1b]9;" in out and b"NOTE-" in out, f"notification not written: {out[-400:]!r}"
    assert b"FRAME-" in out, f"notice not drawn: {out[-400:]!r}"
    assert b"\x1b]52" not in out, "clipboard write reached the terminal"
    assert b"\x1b]2;pwned" not in out, "nested title reached the terminal"
    assert b"\x1b[2J" not in out, "screen clear reached the terminal"


@cleanup.scoped
def osc52_copy_goes_through_the_write_exit(binary):
    # mare.clipboard.copy's OSC 52 path is written by the single write exit (not
    # straight to stdout), reports verified=false, and an over-cap payload writes nothing
    t = Tty.__new__(Tty)
    home = cleanup.directory(prefix="mare-ptyt-cb-")
    os.makedirs(os.path.join(home, "config"), exist_ok=True)
    with open(os.path.join(home, "config", "init.lua"), "w", encoding="utf-8") as f:
        f.write(
            'mare.on("ui/ready", function()\n'
            '  local r = mare.clipboard.copy("hello osc52")\n'
            '  local big = mare.clipboard.copy(string.rep("x", mare.clipboard.max_osc52_bytes + 1))\n'
            '  mare.ui.notify("CB-" .. tostring(r.method) .. "-" .. tostring(r.verified) .. "-" .. tostring(big.ok) .. "-END")\n'
            "end)\n"
        )
    # debug-only seam: skip the native / WSL / tmux paths so OSC 52 is exercised everywhere
    Tty.__init__(t, binary, [], False, {"MARE_HOME": home, "MARE_TEST_CLIPBOARD": "osc52"})
    t.pump(BOOT, until=lambda b: INPUT_BOX in b)
    t.pump(BOOT, until=lambda b: b"CB-" in b and b"-END" in b)
    t.settle(0.3)
    t.quit()
    out = t.out
    assert b"CB-osc52-false-false-END" in out, f"unexpected result: {out[-600:]!r}"
    assert out.count(b"\x1b]52;c;aGVsbG8gb3NjNTI=\x07") == 1, f"OSC 52 not written once: {out[-600:]!r}"
    assert out.count(b"\x1b]52;") == 1, "the over-cap copy reached the terminal"


SCENARIOS = (
    kitty_query_first,
    idle_writes_nothing,
    resize_redraws_at_the_new_width,
    hostile_output_is_filtered,
    extension_points,
    write_paths_are_filtered,
    osc52_copy_goes_through_the_write_exit,
)


def main():
    binary = os.path.abspath(sys.argv[1])
    # every scenario owns its pty, MARE_HOME and process: run them side by side so the wall
    # time is the slowest startup, not the sum of eight (waits are events with ceilings)
    failures = []

    def run(scenario):
        try:
            scenario(binary)
        except BaseException as e:  # noqa: BLE001 - report every scenario's failure
            failures.append((scenario.__name__, e))

    threads = [threading.Thread(target=run, args=(s,), daemon=True) for s in SCENARIOS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if failures:
        for name, e in failures:
            print(f"FAILED {name}: {e!r}", file=sys.stderr)
        sys.exit(1)
    print("ok")


if __name__ == "__main__":
    cleanup.main(main)
