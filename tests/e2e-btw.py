#!/usr/bin/env python3
"""Real faux-model RPC and PTY E2E verification for plugins/btw and core conversations."""
import atexit
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

BINARY, WORK, ROOT = sys.argv[1:]
WORK_DIR = Path(WORK)
ROOT_DIR = Path(ROOT)
PROCESSES = []


def cleanup():
    for proc in PROCESSES:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)


atexit.register(cleanup)


class RpcClient:
    def __init__(self, name, script, resume=False, no_session=False, extra_env=None):
        script_path = ROOT_DIR / f"{name}.json"
        script_path.write_text(json.dumps(script), encoding="utf-8")
        env = dict(os.environ, MARE_FAUX_SCRIPT=str(script_path))
        if extra_env:
            env.update(extra_env)
        args = [BINARY, "-C", WORK, "--rpc"]
        if no_session:
            args.append("--no-session")
        elif resume:
            args += ["--resume", name]
        else:
            args += ["--session-id", name]
        self.p = subprocess.Popen(
            args,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        PROCESSES.append(self.p)
        self.messages = queue.Queue()
        self.events = []
        self.errors = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=lambda: self.errors.extend(self.p.stderr.readlines()), daemon=True).start()
        self.sequence = 0
        self.init_result = self.call(
            "initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "uiContexts": True}}
        )
        methods = (self.init_result.get("capabilities") or {}).get("methods") or []
        assert "agent.get" in methods, self.init_result
        self.has_agent_activity = True

    def sid(self):
        return self.call("status.get")["session"]["session_id"]

    def agent_state(self):
        return self.call("agent.get", {"session_id": self.sid()})

    def activity(self):
        return self.agent_state()["activity"]

    def prompt_wait(self, text):
        sid = self.sid()
        started = self.call("agent.prompt", {"session_id": sid, "input": text})
        return self.call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})

    def _read_stdout(self):
        for line in self.p.stdout:
            msg = json.loads(line)
            if "id" not in msg and "method" in msg:
                self.events.append(msg)
            self.messages.put(msg)
        self.messages.put(None)

    def _read_one(self, deadline):
        remaining = max(0.05, deadline - time.monotonic())
        try:
            msg = self.messages.get(timeout=remaining)
        except queue.Empty:
            raise AssertionError(f"RPC timed out; stderr: {''.join(self.errors)}")
        assert msg is not None, f"RPC closed unexpectedly; stderr: {''.join(self.errors)}"
        return msg

    def send(self, payload):
        self.p.stdin.write(json.dumps(payload) + "\n")
        self.p.stdin.flush()

    def call_raw(self, method, params=None, timeout=20.0):
        self.sequence += 1
        req_id = self.sequence
        self.send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            msg = self._read_one(deadline)
            if msg.get("id") == req_id and "method" not in msg:
                return msg

    def call(self, method, params=None, timeout=20.0):
        msg = self.call_raw(method, params, timeout=timeout)
        assert "error" not in msg, f"RPC {method} failed: {msg}"
        return msg.get("result")

    def until(self, description, fn, timeout=15.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            res = fn()
            if res:
                return res
        raise AssertionError(f"Timed out waiting for: {description}")

    def close(self):
        try:
            self.call("shutdown")
        finally:
            self.p.wait(timeout=10)


def test_rpc_lifecycle_and_non_persistence():
    (WORK_DIR / "readme.txt").write_text("reference material for btw", encoding="utf-8")
    forbidden = WORK_DIR / "forbidden.txt"
    if forbidden.exists():
        forbidden.unlink()

    capture = ROOT_DIR / "capture-lifecycle.jsonl"
    capture.write_text("", encoding="utf-8")
    ops_report = ROOT_DIR / "btw-ops-report.json"
    transcript_report = ROOT_DIR / "btw-transcript.json"
    script = [
        {"text": "parent baseline answer"},
        {"tool_calls": [{"name": "read", "arguments": {"path": "readme.txt"}}]},
        {"text": "side read answer"},
        {"tool_calls": [{"name": "write", "arguments": {"path": "forbidden.txt", "content": "nope"}}]},
        {"text": "side denied write followup"},
        {"text": "parent continued cleanly"},
        {"text": "inline btw answer with SECRET_TOKEN_42"},
    ]
    c = RpcClient(
        "btw-e2e-session",
        script,
        extra_env={
            "BTW_CAPTURE": str(capture),
            "BTW_SECRET": "SECRET_TOKEN_42",
            "BTW_OPS_REPORT": str(ops_report),
            "BTW_SWITCH_PROVIDER": "1",
        },
    )
    try:
        main1 = c.prompt_wait("main question")
        assert main1["text"] == "parent baseline answer", main1

        ops_res = c.call("commands.run", {"line": "/btw-probe-ops"})
        assert ops_report.exists(), f"/btw-probe-ops did not write report; commands.run={ops_res}"
        ops_data = json.loads(ops_report.read_text(encoding="utf-8"))
        assert ops_data.get("ok") is True, ops_data

        c.call("commands.run", {"line": "/side"})
        state = c.agent_state()
        assert "side_id" not in state and "parent_status" not in state and "params" not in state, state
        act = state["activity"]
        btw_act = act["extra"]["btw"]
        assert btw_act["open"] is True and btw_act["selected"] is True and btw_act["parked"] is False

        side1 = c.prompt_wait("read readme.txt")
        assert side1["text"] == "side read answer", side1
        assert any(
            m.get("role") == "tool_result" and "reference material for btw" in json.dumps(m)
            for m in side1["messages"]
        ), side1

        side2 = c.prompt_wait("try writing forbidden.txt")
        assert side2["text"] == "side denied write followup", side2
        assert not forbidden.exists(), "side conversation must not execute mutating writes"
        assert any(
            m.get("role") == "tool_result" and m.get("is_error") is True
            for m in side2["messages"]
        ), side2
        btw_act = c.activity()["extra"]["btw"]
        assert btw_act["turn_count"] == 2, btw_act

        c.call("commands.run", {"line": f"/btw-probe-transcript {transcript_report}"})
        tr_data = json.loads(transcript_report.read_text(encoding="utf-8"))
        assert len(tr_data["turns"]) == 2, tr_data
        assert tr_data["turns"][0]["text"] == "side read answer", tr_data["turns"][0]
        assert tr_data["turns"][0]["tools"][0]["name"] == "read", tr_data["turns"][0]

        # /side back discards the side conversation (leave = discard).
        c.call("commands.run", {"line": "/side back"})
        assert "btw" not in (c.activity().get("extra") or {})

        sid = c.sid()
        main2 = c.prompt_wait("continue main")
        assert main2["text"] == "parent continued cleanly", main2

        msgs_json = json.dumps(c.call("agent.list_messages", {"session_id": sid})["data"])
        assert "parent baseline answer" in msgs_json
        assert "parent continued cleanly" in msgs_json
        assert "side read answer" not in msgs_json
        assert "side denied write followup" not in msgs_json

        # Inline /btw alias + secret projection verification in btw.transcript().
        def wait_btw_settled():
            c.call("commands.run", {"line": f"/btw-probe-transcript {transcript_report}"})
            if not transcript_report.exists():
                return False
            tr = json.loads(transcript_report.read_text(encoding="utf-8"))
            turns = tr.get("turns") or []
            return tr.get("open") is True and len(turns) >= 1 and turns[-1].get("text")

        c.call("commands.run", {"line": "/btw inline check"})
        c.until("inline /btw turn settled", wait_btw_settled)
        inline_tr = json.loads(transcript_report.read_text(encoding="utf-8"))
        assert inline_tr["turns"][0]["prompt"] == "inline check", inline_tr["turns"][0]
        assert "SECRET_TOKEN_42" not in json.dumps(inline_tr), inline_tr
        assert "inline btw answer" in inline_tr["turns"][0]["text"], inline_tr["turns"][0]
        c.call("commands.run", {"line": "/btw close"})
        assert "btw" not in (c.activity().get("extra") or {})

        # A non-streaming provider still records the final answer and prompt.
        c.call("commands.run", {"line": "/btw-probe-model probe-side/nostream"})
        c.call("commands.run", {"line": "/btw no-chunk check"})
        c.until("nostream /btw turn settled", wait_btw_settled)
        nostream_tr = json.loads(transcript_report.read_text(encoding="utf-8"))
        assert nostream_tr["turns"][0]["prompt"] == "no-chunk check", nostream_tr["turns"][0]
        assert nostream_tr["turns"][0]["text"] == "final without chunks", nostream_tr["turns"][0]
        c.call("commands.run", {"line": "/btw close"})
        assert "btw" not in (c.activity().get("extra") or {})
    finally:
        c.close()

    # Resume session and verify zero side-conversation or secret persistence.
    resumed = RpcClient("btw-e2e-session", [], resume=True)
    try:
        resumed_sid = resumed.sid()
        resumed_json = json.dumps(resumed.call("agent.list_messages", {"session_id": resumed_sid})["data"])
        assert "parent baseline answer" in resumed_json
        assert "parent continued cleanly" in resumed_json
        assert "side read answer" not in resumed_json
        assert "side denied write followup" not in resumed_json
        assert "inline btw answer" not in resumed_json
        assert "SECRET_TOKEN_42" not in resumed_json
        assert "btw" not in (resumed.activity().get("extra") or {})
    finally:
        resumed.close()


def test_rpc_concurrent_parent_snapshot_and_model_freeze():
    capture = ROOT_DIR / "capture-concurrent.jsonl"
    capture.write_text("", encoding="utf-8")
    c = RpcClient(
        "btw-concurrent",
        [],
        no_session=True,
        extra_env={"BTW_CAPTURE": str(capture), "BTW_SWITCH_PROVIDER": "1"},
    )
    try:
        sess = c.call("session.create")
        assert sess["session_id"]
        c.call("commands.run", {"line": "/btw-probe-model probe-side/concurrent"})
        parent = c.call("agent.prompt", {"session_id": sess["session_id"], "input": "long parent task"})
        parent_turn = parent["turn_id"]
        c.until(
            "parent streaming started",
            lambda: (
                c.agent_state().get("busy")
                and capture.exists()
                and "llm_stream" in capture.read_text(encoding="utf-8")
            ),
        )
        c.call("commands.run", {"line": "/side"})
        started = c.call("agent.prompt", {"session_id": c.sid(), "input": "what is parent doing?"})
        assert started["status"] == "started", started
        side_turn = started["turn_id"]
        st = c.until(
            "side streaming started",
            lambda: (s := c.agent_state())
            and (s.get("activity") or {}).get("extra", {}).get("btw", {}).get("selected")
            and s.get("busy")
            and s.get("turn_id") == side_turn
            and s,
        )
        btw_act = st["activity"]["extra"]["btw"]
        assert btw_act["open"] is True and btw_act["selected"] is True

        # Abort ONLY the parent turn; side must survive.
        c.call("commands.run", {"line": f"/btw-probe-abort-turn {parent_turn}"})
        st = c.agent_state()
        assert st["activity"]["extra"]["btw"]["open"] is True and st["busy"] and st["turn_id"] == side_turn, st

        # Cancel side turn explicitly to wrap up cleanly.
        cancel_res = c.call("agent.cancel", {"session_id": c.sid()})
        assert "side_only" not in cancel_res, cancel_res
        c.until("side closed after abort", lambda: "btw" not in (c.activity().get("extra") or {}))

        captured = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines() if line.strip()]
        side_streams = [e for e in captured if e.get("kind") == "llm_stream" and e.get("purpose") == "side"]
        assert side_streams, captured
        side_json = json.dumps(side_streams[-1])
        assert "Parent activity" in side_json and "parent partial streaming" in side_json, side_streams[-1]
    finally:
        c.close()

    # Verify side freezes the parent's model when opened before parent switches.
    c_model = RpcClient("btw-freeze", [], no_session=True, extra_env={"BTW_SWITCH_PROVIDER": "1"})
    try:
        c_model.call("commands.run", {"line": "/btw-probe-model probe-side/m1"})
        m1 = c_model.prompt_wait("main1")
        assert m1["text"] == "reply[probe-side/m1]", m1

        c_model.call("commands.run", {"line": "/side"})
        c_model.call("commands.run", {"line": "/btw-probe-model probe-side/m2"})
        side_reply = c_model.prompt_wait("side keeps m1")
        assert side_reply["text"] == "reply[probe-side/m1]", side_reply

        c_model.call("commands.run", {"line": "/side back"})
        assert "btw" not in (c_model.activity().get("extra") or {})
        main2 = c_model.prompt_wait("main uses m2")
        assert main2["text"] == "reply[probe-side/m2]", main2
    finally:
        c_model.close()


def test_real_pty_flow():
    if os.name == "nt":
        print("SKIPPED[capability=posix.pty] POSIX PTY driver")
        sys.exit(77)
    import fcntl
    import select
    import termios

    script_path = ROOT_DIR / "pty-btw.json"
    script_path.write_text(
        json.dumps(
            [
                {"text": "parent pty baseline"},
                {"text": "side pty answer 1"},
                {"text": "side pty inline answer"},
            ]
        ),
        encoding="utf-8",
    )
    env = dict(os.environ, TERM="xterm-256color", MARE_FAUX_SCRIPT=str(script_path))
    env.pop("TMUX", None)
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, b"\x22\x00\x6e\x00\x00\x00\x00\x00")  # 34x110
    p = subprocess.Popen(
        [BINARY, "-C", WORK, "--set", "plugins.onboarding.plugins=false", "--session-id", "btw-pty-session"],
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = b""

    ANSI_CSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]")

    def until(*markers):
        nonlocal output
        deadline = time.monotonic() + 20.0
        while True:
            plain = ANSI_CSI.sub(b"", output)
            if all(m in plain for m in markers):
                output = b""
                return plain.decode("utf-8", "replace")
            assert time.monotonic() < deadline, plain.decode("utf-8", "replace")
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                output += os.read(master, 65536)

    def press_and_redraw(key_bytes):
        nonlocal output
        os.write(master, key_bytes)
        # Wait via select (no sleep) for the terminal redraw after mare processes the key.
        ready, _, _ = select.select([master], [], [], 5.0)
        assert ready, f"Timed out waiting for redraw after {key_bytes!r}"
        output += os.read(master, 65536)
        while select.select([master], [], [], 0.02)[0]:
            output += os.read(master, 65536)

    def submit_and_until(payload, *markers):
        nonlocal output
        not_ready = b"startup is still in progress"
        seen = ANSI_CSI.sub(b"", output).count(not_ready)
        os.write(master, payload + b"\r")
        deadline = time.monotonic() + 20.0
        while True:
            plain = ANSI_CSI.sub(b"", output)
            if all(m in plain for m in markers):
                output = b""
                return plain.decode("utf-8", "replace")
            cur = plain.count(not_ready)
            if cur > seen:
                seen = cur
                # Wait briefly for startup redraws to settle, then resend Enter as the notice instructs.
                settle_until = time.monotonic() + 0.5
                while time.monotonic() < settle_until:
                    ready, _, _ = select.select([master], [], [], 0.05)
                    if ready:
                        output += os.read(master, 65536)
                        settle_until = time.monotonic() + 0.5
                os.write(master, b"\r")
                continue
            assert time.monotonic() < deadline, plain.decode("utf-8", "replace")
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                output += os.read(master, 65536)

    try:
        # Wait for prompt footer before submitting first prompt; retry Enter if two-stage startup is still finishing.
        until(b"faux/echo")
        submit_and_until(b"parent pty question", b"parent pty baseline")

        os.write(master, b"/side\r")
        until(b"SIDE")
        os.write(master, b"first pty side question\r")
        until(b"side pty answer 1")

        # In a real PTY, parent-mutating slash commands are rejected in a side conversation.
        os.write(master, b"/retry\r")
        until(b"/retry is not available")

        # /side back discards the side conversation; re-entering /side starts fresh.
        os.write(master, b"/side back\r")
        back_screen = until(b"Faux Echo")
        assert "Side parked" not in back_screen, back_screen

        os.write(master, b"/side\r")
        fresh_side = until(b"SIDE")
        assert "side pty answer 1" not in fresh_side, fresh_side

        # Press Esc on side editor: returns to main without quitting or "again to exit".
        press_and_redraw(b"\x1b")
        # Submit /btw inline check right after Esc (fails or nests if Esc hadn't closed side!).
        os.write(master, b"/btw quick inline\r")
        inline_screen = until(b"side pty inline answer")
        assert "again to exit" not in inline_screen, inline_screen
        os.write(master, b"/side close\r")
        until(b"Ask mare anything")
        os.write(master, b"/exit\r")
        p.wait(timeout=10)
        assert p.returncode == 0
        final_tail = ANSI_CSI.sub(b"", output).decode("utf-8", "replace")
        assert "Rewind the conversation" not in final_tail
        assert "again to exit" not in final_tail
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=10)
        os.close(master)


test_rpc_lifecycle_and_non_persistence()
test_rpc_concurrent_parent_snapshot_and_model_freeze()
test_real_pty_flow()
print("mare-plugins: btw RPC, concurrent snapshot, model freeze, and PTY checks passed")
