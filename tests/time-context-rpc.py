#!/usr/bin/env python3
"""Real RPC current-run client facts, strict invalid inputs and turn cancellation."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

binary, work, script = sys.argv[1:]
capture = Path(os.environ["TIME_CAPTURE"])
Path(script).write_text(json.dumps([
    {"text": "first stream held for current-run queue", "delay_ms": 100},
    {"text": "mixed run finished"},
    {"text": "new run has one zone"},
    {"text": "new run missing zone"},
    {"text": "recovered after invalid facts"},
    {"text": "modern IANA client facts"},
    {"text": "command facts forwarded"},
    {"text": "cancel this stream before the whole response completes", "delay_ms": 200},
]), encoding="utf-8")
capture.write_text("", encoding="utf-8")
process = subprocess.Popen(
    [binary, "-C", work, "--rpc", "--yolo"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    env=dict(os.environ, TZ="Asia/Tokyo", TIME_SAMPLE_SERIES=json.dumps([1794670200000])),
    encoding="utf-8",
)
ident = 0
seen = []


def call_raw(method, params):
    global ident
    ident += 1
    wanted = ident
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": wanted, "method": method, "params": params}) + "\n")
    process.stdin.flush()
    while True:
        line = process.stdout.readline()
        assert line, process.stderr.read()
        value = json.loads(line)
        if value.get("id") == wanted:
            return value
        if value.get("method") == "event":
            seen.append(value["params"])


def call(method, params):
    value = call_raw(method, params)
    assert "error" not in value, value
    return value.get("result")


def settled(sid):
    deadline = time.monotonic() + 20
    while call("agent.get", {"session_id": sid})["busy"]:
        assert time.monotonic() < deadline, "RPC run never settled"
        time.sleep(0.02)


def records():
    return [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]


def fact(request):
    facts = [message["context_disclosure"]["state"] for message in request["messages"]
             if message.get("context_disclosure", {}).get("namespace") == "time-context"]
    assert facts
    return facts[-1]


def prompt(sid, text, zone=None, wait=True, allow_error=False):
    if zone is not None:
        raw = call_raw(
            "commands.run",
            {
                "line": f"/time-facts {text}",
                "input": {
                    "content": [{"type": "text", "text": text}],
                    "input_context": {"timezone": zone},
                },
            },
        )
        if "error" in raw:
            assert allow_error, raw
            return {"error": raw["error"]}
        res = raw.get("result", {}).get("result")
        if wait and isinstance(res, dict) and res.get("turn_id"):
            return call("agent.wait", {"session_id": sid, "turn_id": res["turn_id"]})
        return res
    started = call("agent.prompt", {"session_id": sid, "input": text})
    if wait and started.get("turn_id"):
        return call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})
    return started


try:
    init_res = call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
    sid = init_res["session"]["session_id"]
    started = prompt(sid, "first current-run zone", "Asia/Tokyo", False)
    assert started["status"] == "started", started
    queued = prompt(sid, "second current-run zone", "America/Los_Angeles", False)
    assert queued["status"] == "queued", queued
    settled(sid)
    sent = records()
    assert len(sent) == 2, sent
    assert fact(sent[0])["client"] == {"kind": "resolved", "zones": ["Asia/Tokyo"]}, fact(sent[0])
    assert fact(sent[1])["client"] == {"kind": "mixed", "zones": ["America/Los_Angeles", "Asia/Tokyo"]}, fact(sent[1])
    run = fact(sent[1])["turn_id"]
    prompt(sid, "a new run only Los Angeles", "America/Los_Angeles")
    selected = fact(records()[-1])
    assert selected["client"] == {"kind": "resolved", "zones": ["America/Los_Angeles"]}
    assert selected["turn_id"] != run
    assert selected["host"]["local_date"] != selected["request_date"], selected
    prompt(sid, "a new run without client facts")
    assert fact(records()[-1])["client"] == {"kind": "missing", "zones": []}, fact(records()[-1])
    before = len(records())
    for invalid in ["america/new_york", "Invalid/Zone", " UTC", "+09:00", "CST6CDT", "EST"]:
        result = prompt(sid, "invalid reported timezone", invalid, allow_error=True)
        assert isinstance(result, dict) and result.get("error"), (invalid, result)
        assert len(records()) == before, "invalid client fact reached a provider"
    prompt(sid, "valid modern IANA client fact recovers", "Asia/Kolkata")
    assert fact(records()[-1])["client"]["zones"] == ["Asia/Kolkata"]
    prompt(sid, "modern IANA client zone facts", "Europe/Kyiv")
    assert fact(records()[-1])["client"]["zones"] == ["Europe/Kyiv"]
    call("commands.run", {"line":"/time-facts through the public command API", "input":{"input_context":{"timezone":"Europe/London"}}})
    settled(sid)
    assert fact(records()[-1])["client"]["zones"] == ["Europe/London"]
    before_cancel = len(records())
    cancel = prompt(sid, "cancel a real provider stream", "Asia/Tokyo", False)
    assert cancel["status"] == "started", cancel
    deadline = time.monotonic() + 10
    while len(records()) == before_cancel:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    call("agent.cancel", {"session_id": sid, "reason": "user"})
    settled(sid)
    messages = call("agent.list_messages", {"session_id": sid})["data"]
    ends = [event["data"] for event in seen if event.get("type") == "turn/completed" and event.get("data", {}).get("turn_id") == cancel["turn_id"]]
    assert ends and ends[-1]["termination_reason"] in ("interrupted", "aborted"), ends
    # The source commit precedes provider I/O; aborting a stream cannot erase committed history.
    assert any(message.get("context_disclosure") for message in messages)
    call("shutdown", {})
    assert process.wait(timeout=10) == 0
    print("time-context real RPC current-run unique/mixed/missing, cross-date, canonical refusal, recovery and abort passed")
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
