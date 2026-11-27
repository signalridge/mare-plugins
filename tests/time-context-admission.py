#!/usr/bin/env python3
"""Actual plugin/model/RPC denial, cancellation and shared writer-failure recovery."""
import json
import os
import subprocess
import sys
from pathlib import Path

binary, work, script = sys.argv[1:]
capture = Path(os.environ["TIME_CAPTURE"])
for mode in ("deny", "cancel", "write-fail"):
    capture.write_text("", encoding="utf-8")
    Path(script).write_text(json.dumps([{"text": "writer recovered"}]), encoding="utf-8")
    process = subprocess.Popen([binary, "-C", work, "--rpc", "--yolo"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=dict(os.environ, TIME_ADMISSION=mode), encoding="utf-8")
    ident = 0

    def call(method, params, process=process):
        global ident
        ident += 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                                        "params": params}) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            assert line, process.stderr.read()
            value = json.loads(line)
            if value.get("id") == ident:
                assert "error" not in value, value
                return value.get("result")

    try:
        call("initialize", {"protocol_version": "3.0"})
        owner = call("session.create", {})
        sid = owner["session_id"]
        started = call("agent.prompt", {"session_id": sid, "input": "source must not commit"})
        refused = call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})
        assert refused.get("error"), refused
        if mode == "cancel":
            assert refused["termination_reason"] == "interrupted" and refused["error_kind"] == "aborted", refused
        assert capture.read_text(encoding="utf-8") == "", "refused source reached a model"
        assert not any(message.get("context_disclosure")
                       for message in call("agent.list_messages", {"session_id": sid})["data"])
        args = {"session_id": sid, "kind": "agent/step-state"}
        assert call("session.list_records", args)["data"] == [], "part of the participant batch committed"
        if mode == "write-fail":
            err = refused["error"]
            assert isinstance(err, dict) and err.get("code") and "TIME_STEP_BATCH_WRITE_FAILURE" in err.get("message", ""), refused
            rec_start = call("agent.prompt", {"session_id": sid, "input": "retry the complete batch"})
            recovered = call("agent.wait", {"session_id": sid, "turn_id": rec_start["turn_id"]})
            assert recovered["text"] == "writer recovered", recovered
            committed = call("session.list_records", args)["data"]
            assert len(committed) == 1
            assert committed[0]["states"]["time-probe-joint"]["value"] == 1
            assert committed[0]["states"]["time-context"]["host"]["local_date"]
            assert len(capture.read_text(encoding="utf-8").splitlines()) == 1
        call("shutdown", {})
        assert process.wait(timeout=10) == 0
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
print("time-context real RPC policy denial, precommit cancel, joint source/state writer failure and recovery passed")
