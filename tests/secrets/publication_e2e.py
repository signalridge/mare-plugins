#!/usr/bin/env python3
"""Structured input publication against the single publication source; synthetic values only."""

import base64
import importlib.util
import json
import os
import queue
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(
    os.environ.get(
        "PUBLICATION_BIN",
        os.environ.get("MARE_BIN", ROOT.parent / "mare/target/debug/mare"),
    )
)
DEV_ENV = {}
SECRET = "FAKE_publication_secret_7ab3"
LATE = "FAKE_publication_late_91d4"


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data))
    )


PNG = (
    b"\x89PNG\r\n\x1a\n"
    + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
    + png_chunk(b"IDAT", zlib.compress(b"\0\xff\0\0\xff"))
    + png_chunk(b"IEND", b"")
)


def run(args, env, cwd):
    result = subprocess.run(
        [str(BIN), "-C", str(cwd), *args],
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=90,
        check=False,
    )
    assert SECRET not in result.stdout + result.stderr
    assert result.returncode == 0, (args, result.stdout, result.stderr)


def check(report, home, expect_queue):
    text = report.read_text(encoding="utf-8")
    assert SECRET not in text and json.dumps(SECRET)[1:-1] not in text
    rows = [json.loads(line) for line in text.splitlines()]
    summary = [row["value"] for row in rows if row["kind"] == "summary"][-1]
    assert summary["structured"] > 0, summary
    if expect_queue:
        assert summary["ready"] >= summary["committed"] > 0 and summary["events"] > 0, (
            summary
        )
        assert any(row["kind"] == "observation" for row in rows)
        assert any(row["kind"] == "queue-edit" for row in rows), text
        assert any(row["kind"] == "settled" for row in rows)
        assert {
            row["value"]["action"] for row in rows if row["kind"] == "rejected"
        } == {"cancel", "switch"}
        assert any(
            row["kind"] == "committed" and row["value"]["durable"] for row in rows
        )
        assert all(
            LATE not in json.dumps(row) for row in rows if row["kind"] != "commit-ready"
        )
    for path in (home / "state").rglob("*"):
        if path.is_file():
            assert SECRET.encode() not in path.read_bytes(), path
            assert LATE.encode() not in path.read_bytes(), path
    return summary["session_id"]


spec = importlib.util.spec_from_file_location(
    "mare_rpc_client", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pty", "rpc_client.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Client(module.Client):
    def __init__(self, *args):
        super().__init__(*args)
        self.received = queue.Queue()
        self.masked = 0

        def read_lines():
            for line in self.p.stdout:
                self.received.put(json.loads(line))
            self.received.put(None)

        threading.Thread(target=read_lines, daemon=True).start()

    def read(self):
        message = self.received.get(timeout=90)
        assert message is not None, "RPC process ended"
        assert SECRET not in json.dumps(message)
        return message

    def dispatch(self, message):
        if message.get("method") == "ui.input":
            assert message["params"]["secret"] is True
            self.masked += 1
            self.send({"id": message["id"], "result": {"text": SECRET}})
            return None
        return super().dispatch(message)


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


tmp = tempfile.mkdtemp(prefix="mpub-")
try:
    top = Path(tmp)
    package = top / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    shutil.copytree(ROOT / "plugins/secrets", package / "plugins/secrets")
    shutil.copytree(
        ROOT / "tests/secrets/publication-probe", package / "plugins/publication-probe"
    )
    subprocess.run(["git", "init", "-q", "-b", "main", str(package)], check=True)
    subprocess.run(["git", "-C", str(package), "add", "."], check=True)
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
            "publication fixture",
        ],
        check=True,
    )
    for mode in ("headless", "rpc"):
        home, work, report = (
            top / mode / "home",
            top / mode / "work",
            top / mode / "report.jsonl",
        )
        (home / "config").mkdir(parents=True)
        work.mkdir(parents=True)
        (work / "publication.txt").write_text("file " + SECRET, encoding="utf-8")
        (home / "config/init.lua").write_text(
            'mare.setup { model="pub-faux/check" }\nmare.plugins.add { {"test/publication",url="'
            + package.as_uri()
            + '"} }\n',
            encoding="utf-8",
        )
        env = dict(
            os.environ,
            MARE_HOME=str(home),
            PUB_MODE=mode,
            PUB_REPORT=str(report),
            PUB_IMAGE=base64.b64encode(PNG).decode(),
            **DEV_ENV,
        )
        run(["plugin", "sync"], env, work)
        if mode == "headless":
            run(
                ["-p", "--json", "--session-id", "pub-session", "post-check"], env, work
            )
            current_session = check(report, home, True)
            report.write_text("", encoding="utf-8")
            env["PUB_MODE"] = "resume"
            run(
                ["-p", "--resume", current_session, "resume structured history"],
                env,
                work,
            )
            check(report, home, False)
        else:
            client = Client([str(BIN), "--rpc", "--session-id", "pub-rpc-session"], env, work)
            try:
                client.call(
                    "initialize",
                    {
                        "protocol_version": "3.0",
                        "capabilities": {"ui": True},
                        "callback_timeout_ms": 10000,
                    },
                )
                client.call("commands.run", {"line": "/secrets add PUB"})
                assert client.masked == 1
                client.call("commands.run", {"line": "/pub-check"})
                client.call("shutdown")
                client.p.wait(timeout=15)
                check(report, home, True)
            finally:
                if client.p.poll() is None:
                    client.p.kill()
                    client.p.wait()
        print("publication structured queue/provider/start/RPC passed:", mode)
finally:
    _rmtree_longpath(Path(tmp))
