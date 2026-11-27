#!/usr/bin/env python3
"""Real PTY masked input, explicit tool approval, safe live tail and abort/recovery."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if os.name == "nt":
    print("secrets PTY TUI suite skipped on Windows (requires POSIX PTY)")
    sys.exit(0)

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("MARE_BIN", ROOT.parent / "mare/target/debug/mare"))
DEV_ENV = {}


def builtin_plugins():
    """The built-in plugin files this core runs (`mare runtime`'s copies)."""
    out = subprocess.run([str(BIN), "runtime"], capture_output=True, text=True, check=True, encoding="utf-8")
    return Path(out.stdout.strip().splitlines()[-1]) / "plugins"
SECRET = "FAKE_registered_secret_83ef"
PTY = ROOT / "tests" / "pty"  # Vendored Python PTY harness.
sys.path.insert(0, str(PTY))
spec = importlib.util.spec_from_file_location(
    "mare_terminal", PTY / "pty_terminal.py"
)
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)
import pty_cleanup as cleanup


def rows(path):
    try:
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []


@cleanup.scoped
def exercise(home, capture, abort):
    env = {
        "MARE_HOME": str(home),
        "SECRETS_MODE": "tui-progress",
        "SECRETS_TUI_ABORT": "1" if abort else "0",
        "SECRETS_CAPTURE": str(capture),
        **DEV_ENV,
    }
    tty = terminal.Tty(str(BIN), ["--yolo", "--session-id", "tui-secret"], False, env)
    tty.ready()
    tty.submit(
        b"/secrets add TEST", lambda out: "Register secret TEST" in terminal.plain(out)
    )
    assert "Register secret TEST" in terminal.plain(tty.out), terminal.plain(
        tty.out[-7000:]
    )
    os.write(tty.master, SECRET.encode() + b"\r")
    tty.pump(15, until=lambda out: "Registered TEST" in terminal.plain(out))
    assert "Registered TEST" in terminal.plain(tty.out)
    tty.pump(terminal.NOTICE_LIFE + 0.2)
    start = len(tty.out)
    tty.submit(b"use TEST", lambda out: "Allow once" in terminal.plain(out[start:]))
    assert "Allow once" in terminal.plain(tty.out[start:])
    os.write(tty.master, b"y")
    # barrier independent of the progress display: the probe records tool-hold once the tool is
    # running; in the abort pass it then holds until cancelled, so Ctrl+C lands while it runs
    tty.pump(15, until=lambda _out: any(r["kind"] == "tool-hold" for r in rows(capture)))
    assert any(r["kind"] == "tool-hold" for r in rows(capture)), terminal.plain(tty.out[-5000:])
    if abort:
        os.write(tty.master, b"\x03")
    tty.pump(
        15,
        until=lambda _out: any(row["kind"] == "agent/settled" for row in rows(capture)),
    )
    assert any(row["kind"] == "agent/settled" for row in rows(capture))
    captured = rows(capture)
    if abort:
        # the cancel reached the running tool: it returned through its cancellation branch
        assert any(r["kind"] == "tool-cancelled" for r in captured), [r["kind"] for r in captured]
    # Live tool partial updates are withheld while sensitive projection is active.
    assert any(
        r["kind"] == "item/completed" and (r.get("data") or {}).get("item", {}).get("type") == "tool_call"
        for r in captured
    ), [r["kind"] for r in captured]
    assert not any(r["kind"] == "progress" for r in captured), captured
    if not abort:
        assert "VISIBLE-PROGRESS" not in terminal.plain(tty.out[start:]), terminal.plain(
            tty.out[-5000:]
        )
    if abort:
        start = len(tty.out)
        settled = sum(row["kind"] == "agent/settled" for row in rows(capture))
        tty.submit(
            b"recover",
            lambda _out: (
                sum(row["kind"] == "agent/settled" for row in rows(capture)) > settled
            ),
        )
        assert sum(row["kind"] == "agent/settled" for row in rows(capture)) > settled
        tty.pump(
            terminal.STEP,
            until=lambda out: "[[mare-value:" in terminal.plain(out[start:]),
        )
        assert "[[mare-value:" in terminal.plain(tty.out[start:])
    tty.quit()
    assert SECRET.encode() not in tty.out and SECRET not in terminal.plain(tty.out)
    summary = [row["data"] for row in rows(capture) if row["kind"] == "summary"][-1]
    assert summary["executions"] == 1 and summary["progress"] == 0, summary
    assert summary["requests"] == 2, summary
    artifact = Path(
        os.environ.get(
            "SECRETS_TUI_ARTIFACT",
            os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "mare-plugins", "secrets-tui"),
        )
    )
    artifact.mkdir(parents=True, exist_ok=True)
    (artifact / ("abort.ansi" if abort else "success.ansi")).write_bytes(tty.out)


with tempfile.TemporaryDirectory(prefix="mare-secret-tui-") as tmp:
    top = Path(tmp)
    package = top / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    shutil.copytree(ROOT / "plugins/secrets", package / "plugins/secrets")
    shutil.copytree(ROOT / "tests/secrets/probe", package / "plugins/secrets-probe")
    # never inherit a caller's GIT_DIR / GIT_WORK_TREE (e.g. `git bisect run`)
    git_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    subprocess.run(["git", "init", "-q", "-b", "main", str(package)], check=True, env=git_env)
    subprocess.run(["git", "-C", str(package), "add", "."], check=True, env=git_env)
    subprocess.run(
        [
            "git",
            "-C",
            str(package),
            "-c",
            "user.name=mare test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "PTY fixture",
        ],
        check=True,
        env=git_env,
    )
    for abort in (False, True):
        home = top / str(abort) / "home"
        (home / "config").mkdir(parents=True)
        disabled = ",".join(
            '["' + file.stem + '"]={enabled=false}'
            for file in builtin_plugins().glob(
                "provider-*.lua"
            )
        )
        (home / "config/init.lua").write_text(
            "mare.setup {plugins={llm={models_dev=false},ui={tool_update_interval_ms=0},"
            + disabled
            + '}}\nmare.plugins.add {{"test/secrets-tui",url="'
            + package.as_uri()
            + '"}}\n',
            encoding="utf-8",
        )
        env = dict(os.environ, MARE_HOME=str(home))
        subprocess.run(
            [str(BIN), "plugin", "sync"], env=env, check=True, capture_output=True
        )
        exercise(home, top / str(abort) / "capture.jsonl", abort)
        print(
            "secrets real PTY registration/approval passed:",
            ("abort-recover" if abort else "success") + " (partial progress withheld under projection)",
        )
