#!/usr/bin/env python3
"""Desired real RPC replay: canonical content/facts, fresh identities and no authority."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

binary, work, script = sys.argv[1:]
capture = Path(os.environ["TIME_CAPTURE"])
capture.write_text("", encoding="utf-8")
Path(script).write_text(json.dumps([
    {"tool_calls": [{"name": "time_replay_grant_probe", "arguments": {}}]}, {"text": "original complete"},
    {"tool_calls": [{"name": "time_replay_grant_probe", "arguments": {}}]}, {"text": "retry complete"},
    {"text": "explicit facts override"}, {"text": "image only"}, {"text": "image only retry"},
]), encoding="utf-8")
process = subprocess.Popen([binary, "-C", work, "--rpc", "--yolo"], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
ident = 0


def call(method, params):
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
            assert "error" not in value, value
            return value.get("result")


def requests():
    return [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]


def settled(sid, minimum):
    deadline = time.monotonic() + 15
    while len(requests()) < minimum or call("agent.get", {"session_id": sid})["busy"]:
        assert time.monotonic() < deadline, "retry never reached the provider and settled"
        time.sleep(0.01)


def human(request):
    return [message for message in request["history"]
            if message.get("role") == "user" and not message.get("notification")][-1]


def fact(request):
    return [message["context_disclosure"]["state"] for message in request["messages"]
            if message.get("context_disclosure", {}).get("namespace") == "time-context"][-1]


image = {"type": "image", "mime": "image/png", "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="}
content = [{"type": "text", "text": "/time-facts original"},
           {"type": "file", "path": "retry-evidence.md", "text": "SNAPSHOT ORIGINAL FILE"}, image]
facts = {"timezone": "Europe/London", "local": True, "approved": True, "evidence": "replay"}
try:
    call("initialize", {"protocol_version": "3.0"})
    owner = call("session.create", {})
    sid = owner["session_id"]
    call("commands.run", {"line": "/time-facts original", "input": {"content": content, "input_context": facts}})
    settled(sid, 2)
    original = human(requests()[0])
    assert original["source"] == "peer" and original.get("input_context") == facts, original
    assert original["content"][1:] == [{"type": "mention", "path": "retry-evidence.md"}, image], original
    assert original["input_id"] and original["turn_id"]
    Path(work, "retry-evidence.md").write_text("MUTATED ON DISK", encoding="utf-8")
    call("commands.run", {"line": "/retry"})
    settled(sid, 4)
    replayed = human(requests()[2])
    assert replayed["source"] == "peer", replayed
    assert replayed["input_id"] != original["input_id"] and replayed["turn_id"] != original["turn_id"]
    assert "MUTATED ON DISK" not in json.dumps(replayed["content"])
    assert not any("text" in block for block in replayed["content"] if block.get("type") == "mention"), replayed
    assert any(message.get("role") == "tool_result" and "REPLAY_GRANT_NOT_INHERITED" in json.dumps(message)
               for message in requests()[3]["messages"])
    assert replayed.get("input_context") == facts, replayed
    assert replayed["content"] == original["content"], "canonical file/image blocks changed during replay"
    assert fact(requests()[2])["client"] == {"kind": "resolved", "zones": ["Europe/London"]}
    override = {"timezone": "Asia/Tokyo", "evidence": "explicit replacement"}
    call("commands.run", {"line": "/retry", "input": {"input_context": override}})
    settled(sid, 5)
    overridden = human(requests()[4])
    assert overridden["input_context"] == override and overridden["source"] == "peer"
    assert overridden["content"] == original["content"]
    assert len({original["input_id"], replayed["input_id"], overridden["input_id"]}) == 3
    assert fact(requests()[4])["client"]["zones"] == ["Asia/Tokyo"]
    accepted = call("commands.run", {"line": "/time-facts", "input": {"content": [image], "input_context": facts}})["result"]
    assert accepted["status"] == "started", accepted
    settled(sid, 6)
    image_only = human(requests()[5])
    assert [block for block in image_only["content"] if block["type"] != "text"] == [image]
    assert not any(block["type"] == "text" and block["text"].strip() for block in image_only["content"])
    call("commands.run", {"line": "/retry"})
    settled(sid, 7)
    repeated_image = human(requests()[6])
    assert repeated_image["content"] == image_only["content"]
    assert repeated_image["input_context"] == facts and repeated_image["source"] == "peer"
    assert repeated_image["input_id"] != image_only["input_id"] and repeated_image["turn_id"] != image_only["turn_id"]
    assert fact(requests()[6])["client"]["zones"] == ["Europe/London"]
    call("shutdown", {})
    assert process.wait(timeout=10) == 0
    print("time-context desired RPC retry retains London/source/file/image, fresh IDs, override, image-only and no grant passed")
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
