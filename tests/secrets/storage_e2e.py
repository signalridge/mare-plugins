#!/usr/bin/env python3
"""Explicit stored-name user flows, isolated fake credential HOME only."""

import importlib.util
import json
import sys
import os
import queue
import shutil
import stat
import subprocess
import tempfile
import threading
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("MARE_BIN", ROOT.parent / "mare/target/debug/mare"))
DEV_ENV = {}
FIRST, SECOND = "FAKE_stored_secret_1a92", "FAKE_rotated_secret_82ab"
spec = importlib.util.spec_from_file_location(
    "rpc", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pty", "rpc_client.py")
)
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


def safe(value):
    text = json.dumps(value)
    assert FIRST not in text and SECOND not in text, text


class Client(rpc.Client):
    def __init__(self, argv, env, cwd, replies=()):
        super().__init__(argv, env, cwd)
        self.replies = deque(replies)
        self.masked = 0
        self.notifications = []
        self.messages = queue.Queue()
        self.on_approval = lambda _p: "allow_session"

        def reader():
            for line in self.p.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)

        threading.Thread(target=reader, daemon=True).start()

    def read(self):
        message = self.messages.get(timeout=60)
        assert message is not None, "RPC process ended"
        safe(message)
        return message

    def dispatch(self, message):
        if message.get("method") == "ui.notify":
            self.notifications.append(message["params"])
            return None
        if message.get("method") == "ui.input":
            assert message["params"]["secret"] is True
            self.masked += 1
            self.send({"id": message["id"], "result": {"text": self.replies.popleft()}})
            return None
        return super().dispatch(message)


def run(args, env, cwd):
    result = subprocess.run(
        [str(BIN), "-C", str(cwd), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
        encoding="utf-8",
    )
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    safe(result.stdout + result.stderr)
    return result


def connect(env, work, replies=()):
    client = Client(
        [str(BIN), "--rpc", "--yolo", "--session-id", "stored-test"], env, work, replies
    )
    client.call(
        "initialize",
        {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}, "callback_timeout_ms": 10000},
    )
    return client


def stop(client):
    try:
        client.call("shutdown")
        client.p.wait(timeout=15)
    finally:
        if client.p.poll() is None:
            client.p.kill()
            client.p.wait()


def _clear_readonly_and_retry(func, path, _exc):
    os.chmod(path, stat.S_IWRITE)
    func(path)


def _rmtree_longpath(path: Path) -> None:
    target = f"\\\\?\\{path.resolve()}" if os.name == "nt" else str(path)
    kw = (
        {"onexc": _clear_readonly_and_retry}
        if sys.version_info >= (3, 12)
        else {"onerror": _clear_readonly_and_retry}
    )
    shutil.rmtree(target, **kw)


td = tempfile.mkdtemp(prefix="msf-")
try:
    top = Path(td)
    package = top / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    shutil.copytree(ROOT / "plugins/secrets", package / "plugins/secrets")
    shutil.copytree(
        ROOT / "tests/secrets/storage-probe", package / "plugins/storage-probe"
    )
    for args in (
        ["init", "-q", "-b", "main"],
        ["add", "."],
        [
            "-c",
            "user.name=mare test",
            "-c",
            "user.email=mare-test@example.invalid",
            "commit",
            "-qm",
            "storage fixture",
        ],
    ):
        subprocess.run(["git", "-C", str(package), *args], check=True)
    home, work = top / "home", top / "work"
    (home / "config").mkdir(parents=True)
    work.mkdir()
    (home / "config/init.lua").write_text(
        'mare.setup {model="stored-faux/m"}\nmare.plugins.add {{"test/stored",url="'
        + package.as_uri()
        + '"}}\n',
        encoding="utf-8",
    )
    report, output = top / "report.jsonl", work / "restored.txt"
    env = dict(
        os.environ,
        MARE_HOME=str(home),
        STORE_MODE="rpc",
        STORE_REPORT=str(report),
        STORE_OUTPUT=str(output),
        **DEV_ENV,
    )
    run(["plugin", "sync"], env, work)
    c = connect(env, work, [None, FIRST, SECOND])
    try:
        c.call("commands.run", {"line": "/storage-check mask-vectors"})
        c.call("commands.run", {"line": "/secrets save bad-name"})
        assert c.masked == 0
        c.call("commands.run", {"line": "/secrets describe STORE"})
        assert "STORE: not configured" in json.dumps(
            c.notifications[-1], ensure_ascii=False
        )
        c.call("commands.run", {"line": "/secrets save STORE"})
        c.call("commands.run", {"line": "/storage-check absent"})
        assert c.call("llm.list_auth_keys", {}) == {"data": []}
        c.call("commands.run", {"line": "/secrets save STORE"})
        assert not output.exists()
        c.call("commands.run", {"line": "/secrets describe STORE"})
        assert "STORE: configured [FAKE_store•••••••••1a92]" in json.dumps(
            c.notifications[-1], ensure_ascii=False
        )
        c.call("commands.run", {"line": "/secrets stored"})
        assert "STORE: configured [FAKE_store•••••••••1a92]" in json.dumps(
            c.notifications[-1], ensure_ascii=False
        ), c.notifications[-3:]
        c.call("commands.run", {"line": "/storage-check stored-one"})
        c.call("commands.run", {"line": "/secrets load STORE"})
        c.call("commands.run", {"line": "/storage-check loaded"})
        c.call("commands.run", {"line": "/storage-check invalid"})
        sid = c.call("status.get", {})["session"]["session_id"]
        s1 = c.call("agent.prompt", {"session_id": sid, "input": "use the explicitly loaded reference"})
        c.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})
        assert output.read_text(encoding="utf-8").splitlines() == ["first"]
        c.call("commands.run", {"line": "/secrets save STORE"})
        c.call("commands.run", {"line": "/secrets load STORE"})
        s2 = c.call("agent.prompt", {"session_id": sid, "input": "use the freshly reloaded value"})
        c.call("agent.wait", {"session_id": sid, "turn_id": s2["turn_id"]})
        assert output.read_text(encoding="utf-8").splitlines() == ["first", "second"]
        c.call("commands.run", {"line": "/storage-check stored"})
        assert c.call("llm.list_auth_keys", {}) == {
            "data": ["mare-plugin/secrets/OTHER", "mare-plugin/secrets/STORE"]
        }
        c.call("commands.run", {"line": "/storage-check child"})
        assert c.masked == 3 and len(c.approvals) == 2
    finally:
        stop(c)
    # Only this fake HOME's documented existing backend is read, never a user credential file.
    auth = home / "config/auth.json"
    if os.name != "nt":
        assert auth.stat().st_mode & 0o077 == 0
    stored = json.loads(auth.read_text(encoding="utf-8"))
    assert stored["mare-plugin/secrets/STORE"]["value"] == SECOND
    env["STORE_MODE"] = "headless"
    headless = run(
        [
            "-p",
            "--yolo",
            "--session-id",
            "stored-restart",
            "load and use after restart",
        ],
        env,
        work,
    )
    # Protected-argument calls require a native human approval receipt,
    # so headless `-p` denies execution and leaves the stored output untouched.
    assert "approval was needed and nobody could answer" in headless.stderr, headless.stderr
    assert output.read_text(encoding="utf-8").splitlines() == ["first", "second"], report.read_text(encoding="utf-8")
    env["STORE_MODE"] = "rpc"
    c = connect(env, work)
    try:
        c.call("commands.run", {"line": "/secrets load STORE"})
        c.call("commands.run", {"line": "/storage-check blank"})
        c.call("commands.run", {"line": "/storage-check malformed"})
        c.call("commands.run", {"line": "/secrets delete STORE"})
        c.call("commands.run", {"line": "/storage-check absent"})
        c.call("commands.run", {"line": "/secrets delete OTHER"})
        c.call("commands.run", {"line": "/storage-check no-stored"})
    finally:
        stop(c)
    assert "mare-plugin/secrets/STORE" not in json.loads(auth.read_text(encoding="utf-8"))
    rows = [json.loads(line) for line in report.read_text(encoding="utf-8").splitlines()]
    safe(rows)
    assert any(row["data"].get("child_checked") for row in rows)
    for path in (home / "state").rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            assert FIRST.encode() not in data and SECOND.encode() not in data, path
    print(
        "stored fake secret masked cancel/save/load/rotate/approval/child/restart/delete passed"
    )
finally:
    _rmtree_longpath(Path(td))
