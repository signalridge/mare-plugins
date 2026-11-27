#!/usr/bin/env python3
"""Actual installed Mermaid producer through native PTY probe and Kitty PNG output.

The Python PTY harness is vendored in tests/pty (core moved its own to Rust).
The existing core terminal harness provides probe emulation and resource cleanup.
No mode, connected state, capabilities or renderer result is injected.
"""

import fcntl
import importlib.util
import json
import os
import pathlib
import signal
import struct
import sys
import termios

ROOT = pathlib.Path(__file__).resolve().parent.parent


def resolve_core_tests():
    # The plugin repository vendors its Python PTY harness.
    return pathlib.Path(__file__).resolve().parent / "pty"


def resolve_binary():
    configured = os.environ.get("MARE_BIN")
    if configured:
        return pathlib.Path(configured)
    return ROOT.parent / "mare" / "target" / "debug" / "mare"


core_tests = resolve_core_tests()
sys.path.insert(0, str(core_tests))
import pty_cleanup as cleanup
from presentation_pty import Terminal, image_records, plain

spec = importlib.util.spec_from_file_location(
    "mermaid_workflow", pathlib.Path(__file__).with_name("mermaid-workflow.py")
)
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


@cleanup.scoped
def actual():
    binary = resolve_binary()
    assert binary.is_file(), f"set MARE_BIN to the matching core executable (tried {binary})"
    home = pathlib.Path(cleanup.directory(prefix="mermaid-actual-pty-")).resolve()
    work = pathlib.Path(cleanup.directory(prefix="mermaid-install-work-")).resolve()
    installer = workflow.Client(binary, home, work, config={"max_rows": 6})
    presenters = installer.call("ui.list_markdown_presenters")["data"]
    assert presenters, "installed Mermaid presenter failed to register"
    installer.close()
    source = "before\n\n> ```mermaid\n> graph TD\n> A[开始]-->B[完成]\n> ```\n\n- list\n\n  > ```mermaid\n  > graph TD\n  > A[开始]-->B[完成]\n  > ```\n\nafter"
    script = home / "faux.json"
    script.write_text(json.dumps([{"text": source}]), encoding="utf-8")
    terminal = Terminal(str(binary), [], str(home), str(script))
    terminal.ready()
    terminal.submit(
        b"render actual Mermaid",
        until=lambda raw: (
            len({record["identity"] for record in image_records(raw)}) >= 2
        ),
    )
    records = image_records(terminal.out)
    assert terminal.version_answered, "native terminal probe was not answered"
    assert len({record["identity"] for record in records}) >= 2, plain(terminal.out)[
        -3000:
    ]
    assert {4, 6}.issubset({record["offset"] for record in records}), records
    assert all(record["size"][0] > 32 and record["size"][1] > 32 for record in records)
    assert "before" in plain(terminal.out) and "after" in plain(terminal.out)
    mark = len(terminal.out)
    os.write(terminal.master, b"\x14")
    terminal.pump(
        20,
        until=lambda raw: (
            bool(image_records(raw[mark:])) and "graph TD" in plain(raw[mark:])
        ),
    )
    assert image_records(terminal.out[mark:]), (
        "owned transcript did not materialize artifact"
    )
    assert "graph TD" in plain(terminal.out[mark:]), (
        "expanded view lost complete fence source"
    )
    mark = len(terminal.out)
    fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 60, 0, 0))
    os.kill(terminal.p.pid, signal.SIGWINCH)
    terminal.pump(20, until=lambda raw: bool(image_records(raw[mark:])))
    assert image_records(terminal.out[mark:]), (
        "resized transcript did not rematerialize picture"
    )
    assert terminal.p.poll() is None
    trace = os.environ.get("MERMAID_TRACE_DIR")
    if trace:
        trace = pathlib.Path(trace)
        trace.mkdir(parents=True, exist_ok=True)
        (trace / "actual-mermaid-pty.ansi").write_bytes(terminal.out)
        (trace / "actual-mermaid-protocol.png").write_bytes(records[0]["png"])
    terminal.quit()


actual()
print(
    "mermaid: installed actual mmdc -> native XTVERSION/cell query -> two Kitty PNG occurrences and quote/list positioning passed"
)
