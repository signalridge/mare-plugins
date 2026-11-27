"""Actual fetch card and saved-session replay on a pseudo-terminal."""

import importlib.util
import json
import os
import sys
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


def save(terminal, label):
    path = (
        Path(
            os.environ.get(
                "WEB_PTY_ARTIFACTS",
                Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "mare-plugins" / "web-ui",
            )
        )
        / f"{time.time_ns()}-{label}"
    )
    path.mkdir(parents=True)
    (path / "terminal.bin").write_bytes(terminal.out)
    (path / "terminal.txt").write_text(harness.plain(terminal.out), encoding="utf-8")
    print(path)


@harness.cleanup.scoped
def main():
    work, script, url = sys.argv[1:4]
    Path(script).write_text(
        json.dumps(
            [
                {
                    "tool_calls": [
                        {
                            "name": "web_search",
                            "arguments": {"queries": ["source fixture"]},
                        }
                    ]
                },
                {"tool_calls": [{"name": "web_fetch", "arguments": {"url": url}}]},
                {"text": "web-ui-finished"},
            ]
        ),
        encoding="utf-8",
    )
    env = {
        "MARE_HOME": os.environ["MARE_HOME"],
        "MARE_FAUX_SCRIPT": script,
        "WEB_SEARCH_FIXTURE": url,
    }
    terminal = harness.Tty(
        os.environ["MARE_BIN"],
        ["-C", work, "--yolo", "--session-id", "web-ui-session"],
        False,
        env,
    )
    try:
        terminal.ready()
        terminal.submit(
            b"fetch a source page", lambda raw: "web-ui-finished" in harness.plain(raw)
        )
        text = harness.plain(terminal.out)
        assert (
            "Fetch:" in text
            and "HTTP 200" in text
            and "Search:" in text
            and "2 sources" in text
        ), text
        os.write(terminal.master, b"\x0f")
        terminal.pump(
            10,
            until=lambda raw: (
                "Source one" in harness.plain(raw)
                and "hello 世界" in harness.plain(raw)
                and url in harness.plain(raw)
            ),
        )
        expanded = harness.plain(terminal.out)
        assert "Source one" in expanded and url in expanded and "hello 世界" in expanded, expanded
    finally:
        save(terminal, "fetch")
        terminal.quit()

    Path(script).write_text(json.dumps([{"text": "web-ui-restored"}]), encoding="utf-8")
    terminal = harness.Tty(
        os.environ["MARE_BIN"],
        ["-C", work, "--yolo", "--resume", "web-ui-session"],
        False,
        env,
    )
    try:
        terminal.ready()
        terminal.pump(
            10,
            until=lambda raw: (
                "Fetch:" in harness.plain(raw)
                and "HTTP 200" in harness.plain(raw)
                and "Search:" in harness.plain(raw)
                and "2 sources" in harness.plain(raw)
            ),
        )
        text = harness.plain(terminal.out)
        assert (
            "Fetch:" in text
            and "HTTP 200" in text
            and "Search:" in text
            and "2 sources" in text
        ), text
        os.write(terminal.master, b"\x0f")
        terminal.pump(
            10,
            until=lambda raw: (
                "Source one" in harness.plain(raw) and "hello 世界" in harness.plain(raw)
            ),
        )
        terminal.submit(
            b"check the previous source",
            lambda raw: "web-ui-restored" in harness.plain(raw),
        )
    finally:
        save(terminal, "restored")
        terminal.quit()

    base = url.rsplit("/", 1)[0]
    Path(script).write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "web_fetch", "arguments": {"url": base + "/error"}}]},
                {"tool_calls": [{"name": "web_fetch", "arguments": {"url": base + "/truncate"}}]},
                {
                    "tool_calls": [
                        {
                            "name": "web_search",
                            "arguments": {"queries": ["osc8 link"]},
                        }
                    ]
                },
                {"text": "web-ui-edge-done"},
            ]
        ),
        encoding="utf-8",
    )
    osc8_env = {**env, "TERM_PROGRAM": "kitty"}
    terminal = harness.Tty(
        os.environ["MARE_BIN"],
        ["-C", work, "--yolo", "--no-session"],
        False,
        osc8_env,
    )
    try:
        terminal.ready()
        terminal.submit(
            b"check osc8, truncation and error cards",
            lambda raw: "web-ui-edge-done" in harness.plain(raw),
        )
        text = harness.plain(terminal.out)
        assert (
            "[truncated]" in text
            and "Fetch:" in text
            and "HTTP 404" in text
            and "HTTP ?" not in text
        ), text
        os.write(terminal.master, b"\x0f")
        terminal.pump(
            10,
            until=lambda raw: (
                "Source one" in harness.plain(raw) and (b"\x1b]8;;" + url.encode()) in raw
            ),
        )
        assert (b"\x1b]8;;" + url.encode()) in terminal.out, terminal.out
    finally:
        save(terminal, "osc8-edge")
        terminal.quit()
    print("web UI: actual fetch card, OSC 8 links, truncation/error cards and saved-session replay passed")


if __name__ == "__main__":
    harness.cleanup.main(main)
