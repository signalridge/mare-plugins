#!/usr/bin/env python3
"""Real agent/tool loop with a deterministic public faux provider and durable records."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BIN = os.environ["MARE_BIN"]

def run(args, env, cwd):
    p = subprocess.run(args, env=env, cwd=cwd, capture_output=True, text=True, timeout=90, encoding="utf-8")
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout

with tempfile.TemporaryDirectory(prefix="mare-terminal-model-") as tmp:
    base = Path(tmp)
    package = base / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    for source in (ROOT / "plugins/terminals", ROOT / "tests/fixtures/terminal-model"):
        shutil.copytree(source, package / "plugins" / source.name)
    for args in (["git", "init", "-q", "-b", "main"], ["git", "add", "plugins", "mare-plugin.toml"],
                 ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]):
        run(args, os.environ.copy(), package)
    config = base / "home/config"
    config.mkdir(parents=True)
    (config / "init.lua").write_text(f'mare.setup {{model="terminal-faux/flow"}}\nmare.plugins.add {{{{"test/terminal",url="{package.as_uri()}"}}}}\n', encoding="utf-8")
    env = os.environ.copy()
    env["MARE_HOME"] = str(base / "home")
    work = base / "work"
    work.mkdir()
    run([BIN, "plugin", "sync"], env, work)
    out = run([BIN, "--yolo", "-p", "--json", "Exercise persistent terminal through the full interaction and recovery flow"], env, work)
    events = [json.loads(line) for line in out.splitlines()]
    completed = [e["data"]["item"] for e in events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call"]
    names = [e["name"] for e in completed]
    assert len(completed) == 12, (names, out)
    assert names.count("terminal_open") == 1 and names.count("terminal_send") == 6, names
    assert "terminal model flow complete" in out, out
    failures = [e for e in completed if e["message"].get("is_error")]
    assert len(failures) == 1 and failures[0]["arguments"]["session_id"] == "foreign", failures
    records = list((base / "home").rglob("*.jsonl"))
    assert records, "durable session was not written"
    assert any("terminal_open" in p.read_text(encoding="utf-8") and "terminal_close" in p.read_text(encoding="utf-8") for p in records)
    if os.name != "nt":
        import fcntl
        import pty
        import select
        import signal
        import struct
        import termios

        report = base / "tui-report.json"
        env.update(TERMINAL_MODEL_REPORT=str(report), TERM="xterm-256color", MARE_NO_TERM_PROBE="1")
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(work)
            os.execvpe(BIN, [BIN, "--yolo", "--set", "plugins.onboarding.plugins=false", "Exercise persistent terminal in the real TUI"], env)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 180, 0, 0))
        capture = bytearray()
        try:
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline and not report.exists():
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try: capture.extend(os.read(master, 65536))
                    except OSError: break
            artifact = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "mare-plugins" / f"terminal-tui-{time.time_ns()}.ansi"
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_bytes(capture)
            assert report.exists() and json.loads(report.read_text(encoding="utf-8"))["ok"], (artifact, capture[-5000:])
            assert b"terminal_send" in capture and b"RECOVERED" in capture, artifact
            next_exit_key = time.monotonic() + 0.5
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if time.monotonic() >= next_exit_key:
                    os.write(master, b"\x04"); next_exit_key = time.monotonic() + 0.5
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended: assert os.waitstatus_to_exitcode(status) == 0; pid = 0; break
                if select.select([master], [], [], 0.1)[0]:
                    try: capture.extend(os.read(master, 65536))
                    except OSError: pass
            artifact.write_bytes(capture)
            assert pid == 0, "TUI did not exit after Ctrl+D"
            print(f"terminal actual TUI cards and model flow capture: {artifact}")
        finally:
            if pid:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(master)
print("terminal deterministic model loop, interactive input, partial submit, independent background send, signal recovery, errors and durable records passed")
