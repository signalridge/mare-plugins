#!/usr/bin/env python3
"""file:// package install and synthetic full model/tool/session flows. No credentials."""

import json
import sys
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("MARE_BIN", ROOT.parent / "mare/target/debug/mare"))
DEV_ENV = {}
SECRET = "FAKE_registered_secret_83ef"


def run(args, env, cwd):
    result = subprocess.run(
        [str(BIN), "-C", str(cwd), *args],
        check=False,
        env=env,
        text=True,
        capture_output=True,
        timeout=45,
        encoding="utf-8",
    )
    if env.get("SECRETS_MODE") == "provider-error" and "-p" in args:
        assert result.returncode == 1, (args, result.stdout, result.stderr)
    else:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    if env.get("SECRETS_MODE") == "started-cancel" and "-p" in args:
        assert "approval was needed and nobody could answer" in result.stderr, (
            args,
            result.stdout,
            result.stderr,
        )
    assert env.get("SECRETS_VALUE", SECRET) not in result.stdout + result.stderr, (
        "registered value escaped UI/error output"
    )
    return result


with tempfile.TemporaryDirectory(prefix="mare-secrets-e2e-") as temp:
    top = Path(temp)
    package = top / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    shutil.copytree(ROOT / "plugins/secrets", package / "plugins/secrets")
    shutil.copytree(ROOT / "tests/secrets/probe", package / "plugins/secrets-probe")
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
            "synthetic secrets fixture",
        ],
        check=True,
    )
    for mode in (
        "child-boundary",
        "progress",
        "conclude",
        "allow",
        "policy-allow",
        "deny",
        "cancel",
        "revoke",
        "churn",
        "error",
        "fallback",
        "late-revoke",
        "running-cancel",
        "retry",
        "provider-error",
        "by-name",
        "attack-quote",
        "attack-semicolon",
        "attack-substitution",
        "attack-newline",
        "file-write",
        "file-write-newline",
        "lua-call",
        "post-approval-revoke",
        "post-approval-churn",
        "started-revoke",
        "started-cancel",
        "bad-enum",
    ):
        # SECRETS_ONLY=mode1,mode2 runs only those modes (debugging aid)
        if os.environ.get("SECRETS_ONLY") and mode not in os.environ["SECRETS_ONLY"].split(","):
            continue
        attacks = {
            "attack-quote": "FAKE_secret'quote\"",
            "attack-semicolon": "FAKE_secret;touch INJECTED;",
            "attack-substitution": "FAKE_$(touch INJECTED)",
            "attack-newline": "FAKE_secret\ntouch INJECTED\n",
            "file-write-newline": "FAKE_secret\nsecond_line\n",
        }
        test_secret = attacks.get(mode, SECRET)
        home, work = top / mode / "home", top / mode / "work"
        (home / "config").mkdir(parents=True)
        work.mkdir(parents=True)
        config = """mare.setup { model = "secrets-faux/echo", fallback_models = { "secrets-faux/fallback" } }
mare.plugins.add { { "test/secrets", url = "__PACKAGE_URI__" } }
""".replace("__PACKAGE_URI__", package.as_uri())
        (home / "config/init.lua").write_text(config, encoding="utf-8")
        capture = top / mode / "capture.jsonl"
        env = dict(
            os.environ,
            MARE_HOME=str(home),
            SECRETS_MODE=mode,
            SECRETS_VALUE=test_secret,
            SECRETS_CAPTURE=str(capture),
            **DEV_ENV,
        )
        run(["plugin", "sync"], env, work)
        session_flags = (
            ["--no-session"]
            if mode in ("lua-call", "child-boundary")
            else ["--session-id", "secret-session"]
        )
        run(
            [
                "--yolo",
                "-p",
                "--json",
                *session_flags,
                ("use TEST" if mode == "by-name" else "use " + test_secret),
            ],
            env,
            work,
        )
        rows = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
        assert (
            test_secret not in capture.read_text(encoding="utf-8")
            and json.dumps(test_secret)[1:-1] not in capture.read_text(encoding="utf-8")
        ), mode
        summary = [row["data"] for row in rows if row["kind"] == "summary"][-1]
        # Protected-argument calls require a native human approval receipt,
        # which headless `-p` cannot provide, so every secret-bearing call in headless is denied
        # as `unavailable` and never executes. Actual execution is verified in the RPC flow below.
        assert summary["executions"] == 0, (mode, summary)
        if (
            mode.startswith("attack-")
            or mode.startswith("file-write")
            or mode
            in (
                "child-boundary",
                "progress",
                "conclude",
                "allow",
                "policy-allow",
                "error",
                "fallback",
                "late-revoke",
                "running-cancel",
                "retry",
                "by-name",
                "lua-call",
            )
        ):
            assert any(
                row["kind"] == "approval/resolved"
                and (row["data"].get("result") or {}).get("decision") == "unavailable"
                for row in rows
            ), (mode, rows)
        if mode.startswith("file-write"):
            target = work / "registered-value.txt"
            assert not target.exists() or target.read_text(encoding="utf-8") == "before\n", (
                mode,
                target.read_text(encoding="utf-8"),
            )
        assert summary["approvals"] >= (
            0 if mode in ("provider-error", "bad-enum") else 1
        ), (mode, summary)
        assert summary["chunks"] >= (
            0 if mode in ("cancel", "started-cancel", "conclude") else 1
        ), (mode, summary)
        # compact / aux / btw come from the probe's app/ready flow, independent of the tool call
        log = home / "state/log/mare.log"
        assert any(row["kind"] == "compact" for row in rows), (
            mode,
            log.read_text(errors="replace", encoding="utf-8")[-2000:] if log.exists() else "no mare.log",
        )
        assert any(
            row["kind"] == "request" and row["data"].get("purpose") == "auxiliary"
            for row in rows
        )
        assert (
            sum(
                row["kind"] == "request" and row["data"].get("purpose") == "btw"
                for row in rows
            )
            == 2
        )
        assert any(
            row["kind"] == "provider-accessor"
            and row["data"].get("stream")
            and row["data"].get("compact")
            and row["data"].get("old_generation_refused")
            for row in rows
        ), (mode, rows)
        for path in home.rglob("*"):
            if path.is_file() and (
                "state" in path.relative_to(home).parts
                or path.suffix in (".json", ".jsonl", ".log")
            ):
                assert (
                    test_secret.encode() not in path.read_bytes()
                    and json.dumps(test_secret)[1:-1].encode() not in path.read_bytes()
                ), (mode, path)
        if mode == "allow":
            before = len(rows)
            env["SECRETS_MODE"] = "resume"
            run(
                ["-p", "--resume", "secret-session", "try the old reference"], env, work
            )
            resumed = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()][
                before:
            ]
            last = [row["data"] for row in resumed if row["kind"] == "summary"][-1]
            assert last["executions"] == 0 and last["registrations"] == 0, last
        print("secrets full file:// faux flow passed:", mode)

    # Real public RPC UI callbacks: cancel masked input, register, model tool use, remove.
    import queue
    import threading

    home, work = top / "rpc/home", top / "rpc/work"
    (home / "config").mkdir(parents=True)
    work.mkdir(parents=True)
    (home / "config/init.lua").write_text(config, encoding="utf-8")
    capture = top / "rpc/capture.jsonl"
    env = dict(
        os.environ,
        MARE_HOME=str(home),
        SECRETS_MODE="rpc",
        SECRETS_CAPTURE=str(capture),
        **DEV_ENV,
    )
    run(["plugin", "sync"], env, work)
    proc = subprocess.Popen(
        [str(BIN), "-C", str(work), "--rpc", "--yolo", "--session-id", "rpc-secret"],
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        encoding="utf-8",
    )
    incoming = queue.Queue()

    def reader():
        for line in proc.stdout:
            incoming.put(json.loads(line))
        incoming.put(None)

    threading.Thread(target=reader, daemon=True).start()
    sequence, masked, approved, notifications, input_reply = 0, 0, 0, [], None

    def send(message):
        proc.stdin.write(json.dumps(dict(jsonrpc="2.0", **message)) + "\n")
        proc.stdin.flush()

    def call(method, params=None):
        global sequence, masked, approved
        sequence += 1
        rid = sequence
        send({"id": rid, "method": method, "params": params or {}})
        while True:
            msg = incoming.get(timeout=30)
            assert msg is not None, proc.stderr.read()
            assert SECRET not in json.dumps(msg), "raw value escaped RPC response/event"
            if "method" in msg:
                kind, data = msg["method"], msg.get("params", {})
                if kind == "ui.input":
                    assert data["secret"] is True
                    masked += 1
                    send(
                        {
                            "id": msg["id"],
                            "result": {"text": input_reply},
                        }
                    )
                elif kind == "approval.request":
                    approved += 1
                    assert "hidden" in data["reason"].lower(), data
                    send({"id": msg["id"], "result": {"decision": "allow_session"}})
                elif kind == "ui.notify":
                    notifications.append(data)
                elif "id" in msg:
                    send({"id": msg["id"], "result": {}})
            elif msg.get("id") == rid:
                assert "error" not in msg, msg
                return msg.get("result")

    try:
        call(
            "initialize",
            {
                "protocol_version": "3.0",
                "capabilities": {"ui": True, "approvals": True},
                "callback_timeout_ms": 10000,
            },
        )
        call("commands.run", {"line": "/secrets add CANCELLED"})
        assert masked == 1
        input_reply = ""
        call("commands.run", {"line": "/secrets add EMPTY"})
        assert masked == 2 and notifications[-1]["level"] == "error"
        assert "non-empty string" in json.dumps(notifications[-1])
        input_reply = SECRET
        call("commands.run", {"line": "/secrets add bad-name"})
        assert masked == 2 and notifications[-1]["level"] == "error"
        assert "Invalid secret name" in json.dumps(notifications[-1])
        call("commands.run", {"line": "/secrets add TEST"})
        assert masked == 3
        call("commands.run", {"line": "/secrets add TEST"})
        assert masked == 3 and notifications[-1]["level"] == "error"
        assert "already registered" in json.dumps(notifications[-1])
        call("commands.run", {"line": "/secrets remove bad-name"})
        assert notifications[-1]["level"] == "error"
        assert "Invalid secret name" in json.dumps(notifications[-1])
        call("commands.run", {"line": "/secrets unknown"})
        assert notifications[-1]["level"] == "error"
        assert "Usage:" in json.dumps(notifications[-1])
        call("commands.run", {"line": "/secrets list"})
        assert any("[[mare-value:" in json.dumps(note) for note in notifications)
        sid = call("status.get", {})["session"]["session_id"]
        started = call("agent.prompt", {"session_id": sid, "input": "use " + SECRET})
        call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})
        assert approved == 1
        import re

        old_reference = re.search(
            r"\[\[mare-value:[a-z0-9-]+\]\]", json.dumps(notifications)
        ).group()
        sid2 = call("session.create", {})["session_id"]
        started2 = call("agent.prompt", {"session_id": sid2, "input": "old reference " + old_reference})
        call("agent.wait", {"session_id": sid2, "turn_id": started2["turn_id"]})
        assert (
            approved == 1
        )  # revoked reference fails native validation before a second approval
        call("session.close", {"session_id": sid2})
        call("session.load", {"session_id": sid})
        call("commands.run", {"line": "/secrets remove TEST"})
        assert notifications[-1]["text"] == "Registration revoked", notifications[-1]
        call("commands.run", {"line": "/secrets clear"})
        call("commands.run", {"line": "/secrets list"})
        assert "No active secrets registered" in notifications[-1]["text"] or "none" in notifications[-1]["text"].lower() or "TEST" not in notifications[-1]["text"], notifications[-1]
        call("shutdown")
        proc.wait(timeout=10)
        rows = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
        summaries = [row["data"] for row in rows if row["kind"] == "summary"]
        assert all(s["registrations"] == 0 for s in summaries), summaries
        summary = summaries[-1]
        assert summary["executions"] == 1 and summary["registrations"] == 0, summary
        print(
            "secrets RPC masked registration/cancel, UI display, explicit approval and removal passed"
        )
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
