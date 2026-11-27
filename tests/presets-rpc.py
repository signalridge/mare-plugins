#!/usr/bin/env python3
"""Drive the real preset picker through JSON-RPC UI, cancellation and model requests."""
import json
import os
import pathlib
import queue
import subprocess
import sys
import threading

binary, work = sys.argv[1:]
capture = pathlib.Path(os.environ["PRESETS_CAPTURE"])
capture.write_text("", encoding="utf-8")
pathlib.Path(os.environ["MARE_FAUX_SCRIPT"]).write_text(
    json.dumps(
        [
            {"text": "startup default"},
            {"text": "picker selected"},
            {"text": "cancel retained"},
            {"text": "cleared"},
            {"text": "new session default"},
            {"text": "new session selected default"},
            {"text": "clear keeps selected model"},
            {"text": "new session staged persona"},
            {"text": "new session fallback default"},
        ]
    ),
    encoding="utf-8",
)
process = subprocess.Popen([binary, "--rpc", "-C", work], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
lines = queue.Queue()


def _read_stdout():
    while True:
        line = process.stdout.readline()
        lines.put(line)
        if not line:
            break


threading.Thread(target=_read_stdout, daemon=True).start()
sequence = 0
choice = "review"
expected_default = "review"
dialogs = 0
seen_staged = False


def send(message):
    process.stdin.write((json.dumps(message) + "\n").encode())
    process.stdin.flush()


def call(method, params):
    global sequence, dialogs, seen_staged
    sequence += 1
    request_id = sequence
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    while True:
        try:
            line = lines.get(timeout=20)
        except queue.Empty:
            raise AssertionError(f"RPC timeout for {method}")
        assert line, "RPC exited: " + process.stderr.read().decode()
        message = json.loads(line)
        if "method" in message:
            if "id" not in message:
                continue
            assert message["method"] == "ui.select", message
            dialogs += 1
            options = message["params"]
            assert options["title"] == "Presets", options
            items = options["items"]
            assert any(
                "broken" in item["label"]
                and item.get("disabled")
                and (item.get("preview") or {}).get("type") == "lines"
                and any("Broken:" in line for line in item["preview"].get("items", []))
                for item in items
            ), items
            assert any(item["label"].startswith(expected_default) and "(default)" in item["label"] for item in items), items
            if any(item["label"].startswith("persona") and "(staged)" in item["label"] for item in items):
                seen_staged = True
            selected = None if choice is None else next(i for i, item in enumerate(items) if item["label"].startswith(choice))
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"index": selected}})
        elif message.get("id") == request_id:
            assert "error" not in message, message
            return message.get("result")


def command_status(text):
    # commands.run returns {result?} on success and raises a coded RPC error on failure:
    # an explicit status table comes back as {result = {status}}; a command that returns
    # nothing on success comes back as {} - that is completed.
    reply = call("commands.run", {"line": text})
    assert isinstance(reply, dict) and "ok" not in reply and "message" not in reply, reply
    result = reply.get("result")
    status = result.get("status") if isinstance(result, dict) else None
    return "completed" if status is None else status


def prompt_wait(text):
    sid = call("status.get", {})["session"]["session_id"]
    started = call("agent.prompt", {"session_id": sid, "input": text})
    return call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})


try:
    call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
    prompt_wait("check startup default")
    assert command_status("/preset") == "completed"
    prompt_wait("check picker selection")
    choice = None
    assert command_status("/preset") == "cancelled"
    prompt_wait("check cancelled selection")
    assert command_status("/preset help") == "completed"
    assert command_status("/preset inspect review") == "completed"
    assert command_status("/preset inspect broken") == "completed"
    assert command_status("/preset clear") == "completed"
    prompt_wait("check cleared selection")
    assert command_status("/new") == "completed"
    prompt_wait("check /new reapplies default")
    assert command_status("/preset default selected") == "completed"
    expected_default = "selected"
    assert command_status("/new") == "completed"
    prompt_wait("check /new applies updated default model")
    assert command_status("/preset clear") == "completed"
    prompt_wait("check /preset clear keeps model and does not reapply default")
    assert command_status("/preset stage persona") == "completed"
    choice = None
    assert command_status("/preset") == "cancelled"
    assert seen_staged, "expected (staged) badge in RPC picker"
    assert command_status("/new") == "completed"
    prompt_wait("check /new consumes staged persona")
    assert command_status("/new") == "completed"
    prompt_wait("check second /new falls back to default")
    requests = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
    assert len(requests) == 9 and dialogs == 3, (requests, dialogs)
    assert all("PRESET_GUIDANCE" in request["system"] and request["tools"] == ["read"] for request in requests[:3])
    assert "PRESET_GUIDANCE" not in requests[3]["system"] and len(requests[3]["tools"]) > 1
    assert "PRESET_GUIDANCE" in requests[4]["system"] and requests[4]["tools"] == ["read"]
    assert (
        requests[5]["model"] == "presets-faux/selected"
        and requests[5]["effort"] == "high"
        and requests[5]["tools"] == ["read"]
        and "MODEL_GUIDANCE" in requests[5]["system"]
    )
    assert (
        requests[6]["model"] == "presets-faux/selected"
        and "MODEL_GUIDANCE" not in requests[6]["system"]
        and len(requests[6]["tools"]) > 1
    )
    assert (
        "PERSONA_PREFIX" in requests[7]["system"]
        and "PERSONA_SUFFIX" in requests[7]["system"]
        and "<environment>" not in requests[7]["system"]
        and "write" not in requests[7]["tools"]
    )
    assert (
        requests[8]["model"] == "presets-faux/selected"
        and requests[8]["effort"] == "high"
        and requests[8]["tools"] == ["read"]
        and "MODEL_GUIDANCE" in requests[8]["system"]
        and "PERSONA_PREFIX" not in requests[8]["system"]
    )
    print("presets real RPC picker, broken row, cancel retention, inspect, /new default/staged and model request checks passed")
finally:
    process.stdin.close()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
