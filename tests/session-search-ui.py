"""Real consumer card, visible resume search, Esc and selected-session restore on a PTY."""

import os
import sys

if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)

import importlib.util
import json
import re
import shutil
import time
from pathlib import Path

PTY = Path(__file__).resolve().parent / "pty"  # Vendored Python PTY harness.
sys.path.insert(0, str(PTY))
spec = importlib.util.spec_from_file_location(
    "mare_pty", PTY / "pty_terminal.py"
)
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)
harness.BOOT = 20
ARTIFACTS = Path(
    os.environ.get(
        "HISTORY_PTY_ARTIFACTS",
        os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "mare-plugins", "session-search-pty"),
    )
)


def save(terminal, label):
    path = ARTIFACTS / (label + "-" + str(time.time_ns()))
    path.mkdir(parents=True)
    (path / "terminal.bin").write_bytes(terminal.out)
    (path / "terminal.txt").write_text(harness.plain(terminal.out), encoding="utf-8")
    return path


@harness.cleanup.scoped
def main():
    work, script = sys.argv[1:]
    Path(script).write_text(
        json.dumps(
            [
                {
                    "tool_calls": [
                        {
                            "name": "session_event_search",
                            "arguments": {
                                "session_id": "history-one",
                                "query": "needle",
                                "seq_from": 121,
                                "seq_to": 125,
                            },
                        }
                    ]
                },
                {"text": "history-ui-done"},
            ]
        ),
        encoding="utf-8",
    )
    env = {"MARE_HOME": os.environ["MARE_HOME"], "MARE_FAUX_SCRIPT": script}
    terminal = harness.Tty(os.environ["MARE_BIN"], ["-C", work, "--yolo"], False, env)
    try:
        terminal.ready()
        terminal.submit(
            b"inspect historical evidence",
            lambda raw: "history-ui-done" in harness.plain(raw),
        )
        text = harness.plain(terminal.out)
        assert "history-ui-done" in text and "History" in text and "5 match" in text, (
            text
        )
    finally:
        save(terminal, "consumer-render")
        terminal.quit()
    requests = [
        json.loads(line)
        for line in Path(os.environ["HISTORY_CAPTURE"]).read_text(encoding="utf-8").splitlines()
    ]
    restore_id = requests[-1]["session"]["session_id"]
    state_path = Path(script).with_suffix(".state.json")
    event_path = Path(str(state_path) + ".events")
    env["HISTORY_UI_STATE"] = str(state_path)
    env["HISTORY_RESTORE_ID"] = restore_id
    seed_dir = Path(os.environ["HISTORY_SEED_PATH"]).parent
    scroll_files = []
    for idx in range(12):
        sf = seed_dir / f"ui-scroll-{idx:02d}.jsonl"
        sid = f"ui-scroll-{idx:02d}"
        sf.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "type": "session",
                            "version": 3,
                            "session_id": sid,
                            "cwd": work,
                            "created_at_ms": 1000 + idx,
                        }
                    ),
                    json.dumps(
                        {
                            "type": "name",
                            "name": f"Scroll Candidate {idx:02d}",
                        }
                    ),
                    json.dumps(
                        {
                            "type": "message",
                            "entry_id": f"sm-{idx}",
                            "created_at_ms": 2000 + idx,
                            "message": {
                                "role": "assistant",
                                "content": f"needle scroll candidate {idx:02d}",
                            },
                        }
                    ),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        scroll_files.append(sf)
    terminal = harness.Tty(os.environ["MARE_BIN"], ["-C", work, "--yolo"], False, env)
    before = {}
    after = {}

    def events():
        try:
            return [json.loads(line) for line in event_path.read_text(encoding="utf-8").splitlines()]
        except (FileNotFoundError, json.JSONDecodeError):
            return []

    def command(text, until):
        mark = len(terminal.out)
        os.write(terminal.master, b"\x1b[200~" + text + b"\x1b[201~")
        terminal.pump(5, until=lambda raw: text.decode() in harness.plain(raw[mark:]))
        # Native paste.rs:25,85: deliberate Enter follows the 150ms stray-Enter guard.
        terminal.settle(0.2)
        os.write(terminal.master, b"\r")
        terminal.pump(harness.BOOT, until=until)

    def state():
        state_path.unlink(missing_ok=True)
        command(b"/history-state", lambda _: state_path.exists())
        assert state_path.exists(), harness.plain(terminal.out)
        terminal.settle(0.2)
        return json.loads(state_path.read_text(encoding="utf-8"))

    def search():
        mark = len(terminal.out)
        # Matching raw bytes stops on an earlier OSC window-title update, before the modal.
        command(
            b"/resume search needle",
            lambda raw: "Sessions containing" in harness.plain(raw[mark:])
            and "Enter select" in harness.plain(raw[mark:]),
        )
        assert "Sessions containing" in harness.plain(terminal.out[mark:]), (
            harness.plain(terminal.out)
        )
        return mark

    try:
        terminal.ready()
        before = state()
        assert before["available"] and not before["busy"], before
        empty_mark = len(terminal.out)
        command(
            b"/resume search nonexistent_ui_query_999",
            lambda raw: "No matching sessions" in harness.plain(raw[empty_mark:]),
        )
        assert "No matching sessions" in harness.plain(terminal.out[empty_mark:]), (
            harness.plain(terminal.out)
        )
        search()
        os.write(terminal.master, b"\x1b")
        terminal.pump(
            harness.BOOT,
            until=lambda _: any(e["event"] == "ui/wait-completed" for e in events()),
        )
        terminal.settle(0.2)
        cancelled = state()
        assert cancelled["session"]["session_id"] == before["session"]["session_id"], cancelled
        assert any(e["event"] == "ui/wait-started" for e in events()), events()

        search()
        filter_mark = len(terminal.out)
        os.write(
            terminal.master,
            b"\x1b[200~" + before["restore_short"].encode() + b"\x1b[201~",
        )
        terminal.pump(
            harness.BOOT, until=lambda raw: "1 of 1" in harness.plain(raw[filter_mark:])
        )
        assert "1 of 1" in harness.plain(terminal.out[filter_mark:]), harness.plain(
            terminal.out
        )
        terminal.settle(0.2)

        def changes_since(mark):
            return [e for e in events()[mark:] if e["event"] == "session/changed"]

        def select(mark):
            """Enter in the picker; the session/changed events it caused (a pump timeout is not a pass)."""
            os.write(terminal.master, b"\r")
            terminal.pump(harness.BOOT, until=lambda _: changes_since(mark))
            return changes_since(mark)

        event_mark = len(events())
        changed = select(event_mark)
        assert changed, ("paste filter + Enter switched no session", events()[event_mark:])
        assert all(e["value"].get("session_id") == restore_id for e in changed), (restore_id, changed)
        terminal.settle(0.2)
        after = state()
        assert after["session"]["session_id"] == restore_id != before["session"]["session_id"], after

        # Scroll down 3 items in multi-result search modal and restore the scrolled-to session
        scroll_mark = search()
        first_modal = harness.plain(terminal.out[scroll_mark:])
        counts = re.findall(r"\b(\d+) of (\d+)\b", first_modal)
        assert counts and int(counts[-1][1]) >= 12, first_modal
        for k in range(1, 4):
            step_mark = len(terminal.out)
            os.write(terminal.master, b"\x1b[B")
            terminal.pump(
                harness.BOOT,
                until=lambda raw, sm=step_mark, target=f"candidate {k:02d}": (
                    target in harness.plain(raw[sm:]).lower()
                ),
            )
        scroll_changes = select(len(events()))
        assert scroll_changes and all(
            e["value"].get("session_id") == "ui-scroll-03" for e in scroll_changes
        ), scroll_changes
        terminal.settle(0.2)
        scrolled = state()
        assert scrolled["session"]["session_id"] == "ui-scroll-03", scrolled
    finally:
        for sf in scroll_files:
            sf.unlink(missing_ok=True)
        artifacts = save(terminal, "resume-flow")
        if event_path.exists():
            shutil.copyfile(event_path, artifacts / "public-events.jsonl")
        (artifacts / "observation.json").write_text(
            json.dumps(
                {
                    "argv": [os.environ["MARE_BIN"], "-C", work, "--yolo"],
                    "explicit_no_session": False,
                    "before": before,
                    "after": after,
                    "restore_id": restore_id,
                    "raw_input": terminal.raw(),
                    "process_code": terminal.p.poll(),
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        try:
            shutil.copytree(
                os.environ["MARE_HOME"],
                artifacts / "fixture-home",
                dirs_exist_ok=True,
                ignore=lambda directory, names: [
                    n
                    for n in names
                    if not (Path(directory) / n).is_file()
                    and not (Path(directory) / n).is_dir()
                ],
            )
        except (shutil.Error, OSError) as error:
            (artifacts / "copy-errors.txt").write_text(str(error), encoding="utf-8")
        print("Session search UI artifacts:", artifacts, file=sys.stderr)
        terminal.quit()

    # Busy guard: /resume must refuse while a turn is running, then succeed once idle
    busy_script = Path(script).with_name("busy-ui.json")
    busy_events = Path(str(busy_script) + ".events")
    busy_events.unlink(missing_ok=True)
    fifo_path = Path(script).with_name("busy.fifo")
    ready_file = Path(script).with_name("busy.ready")
    fifo_path.unlink(missing_ok=True)
    ready_file.unlink(missing_ok=True)
    os.mkfifo(fifo_path)
    busy_script.write_text(
        json.dumps(
            [
                {
                    "tool_calls": [
                        {
                            "name": "bash",
                            "arguments": {
                                "command": f"printf ready > '{ready_file}' && cat < '{fifo_path}'"
                            },
                        }
                    ]
                },
                {"text": "busy-turn-finished"},
            ]
        ),
        encoding="utf-8",
    )
    busy_env = {
        "MARE_HOME": os.environ["MARE_HOME"],
        "MARE_FAUX_SCRIPT": str(busy_script),
        "HISTORY_UI_STATE": str(busy_script.with_suffix(".state.json")),
        "HISTORY_RESTORE_ID": restore_id,
    }
    busy_term = harness.Tty(
        os.environ["MARE_BIN"], ["-C", work, "--yolo"], False, busy_env
    )
    try:
        busy_term.ready()
        os.write(busy_term.master, b"hold turn busy\r")
        busy_term.pump(harness.BOOT, until=lambda _: ready_file.exists())
        busy_mark = len(busy_term.out)
        os.write(busy_term.master, b"\x1b[200~/resume search needle\x1b[201~")
        busy_term.pump(
            5,
            until=lambda raw: "/resume search needle" in harness.plain(raw[busy_mark:]),
        )
        # Wait past the 150ms stray-Enter paste guard without settle(), which waits for
        # spinner silence while the turn is running.
        busy_term.pump(0.2)
        os.write(busy_term.master, b"\r")
        busy_term.pump(
            harness.BOOT,
            until=lambda raw: (
                "/resume isn't available" in harness.plain(raw[busy_mark:])
                and "Esc stops it" in harness.plain(raw[busy_mark:])
            ),
        )
        busy_plain = harness.plain(busy_term.out[busy_mark:])
        assert "/resume isn't available" in busy_plain and "Esc stops it" in busy_plain, (
            harness.plain(busy_term.out)
        )
        with open(fifo_path, "w", encoding="utf-8") as f:
            f.write("go\n")
        busy_term.pump(
            harness.BOOT,
            until=lambda raw: (
                "busy-turn-finished" in harness.plain(raw)
                and "Ask mare anything" in harness.plain(raw).split("busy-turn-finished", 1)[1]
            ),
        )
        if busy_events.exists():
            lines = [json.loads(l) for l in busy_events.read_text(encoding="utf-8").splitlines() if l]
            assert not any(e["event"] == "session/changed" for e in lines), lines
        idle_mark = len(busy_term.out)
        # Clear any command text preserved after the busy-guard refusal (Ctrl+U).
        os.write(busy_term.master, b"\x15\x1b[200~/resume search needle\x1b[201~")
        busy_term.pump(
            5,
            until=lambda raw: "/resume search needle" in harness.plain(raw[idle_mark:]),
        )
        busy_term.settle(0.2)
        os.write(busy_term.master, b"\r")
        busy_term.pump(
            harness.BOOT,
            until=lambda raw: "Sessions containing" in harness.plain(raw[idle_mark:]),
        )
        assert "Sessions containing" in harness.plain(busy_term.out[idle_mark:]), (
            harness.plain(busy_term.out[idle_mark:])
        )
    finally:
        save(busy_term, "busy-guard")
        fifo_path.unlink(missing_ok=True)
        ready_file.unlink(missing_ok=True)
        busy_term.quit()


if __name__ == "__main__":
    harness.cleanup.main(main)
