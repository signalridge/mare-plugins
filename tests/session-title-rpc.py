"""Exercise the installed title plugin through real RPC and offline faux requests."""

import json
import queue
import subprocess
import sys
import threading
import time

binary, work = sys.argv[1:]
p = subprocess.Popen(
    [binary, "-C", work, "--rpc", "--yolo"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    encoding="utf-8",
)
serial = 0
events = []
incoming = queue.Queue()


def _reader():
    for line in p.stdout:
        incoming.put(json.loads(line))
    incoming.put(None)


threading.Thread(target=_reader, daemon=True).start()


def read_message(deadline):
    remaining = deadline - time.monotonic()
    assert remaining > 0, f"RPC timeout; stderr={p.stderr.read()}"
    try:
        item = incoming.get(timeout=remaining)
    except queue.Empty:
        raise AssertionError(f"RPC timeout; events={events}") from None
    assert item is not None, p.stderr.read()
    return item


def call(method, params=None):
    global serial
    serial += 1
    p.stdin.write(
        json.dumps(
            {"jsonrpc": "2.0", "id": serial, "method": method, "params": params or {}}
        )
        + "\n"
    )
    p.stdin.flush()
    deadline = time.monotonic() + 25
    while True:
        message = read_message(deadline)
        if message.get("method") == "event":
            events.append(message["params"])
        elif message.get("id") == serial:
            assert "error" not in message, message
            return message["result"]


def wait_provider_commit(start_index):
    deadline = time.monotonic() + 10
    while True:
        while start_index < len(events):
            ev = events[start_index]
            start_index += 1
            if ev.get("type") == "session-title/changed":
                state = ev["data"]["state"]
                if (state.get("metadata") or {}).get("source") == "provider":
                    return state, start_index
        message = read_message(deadline)
        if message.get("method") == "event":
            events.append(message["params"])


def prompt_wait(sid, text):
    started = call("agent.prompt", {"session_id": sid, "input": text})
    return call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})


try:
    init = call("initialize", {"protocol_version": "3.0"})
    sid = init["session"]["session_id"]
    call(
        "events.subscribe",
        {"session_id": sid, "include": ["session-title/*", "turn/*", "item/*", "status/*", "session/*"]},
    )
    seen = len(events)
    prompt_wait(sid, "implement parser")
    first, seen = wait_provider_commit(seen)
    assert first["name"]
    prompt_wait(sid, "continue the same parser")
    _, seen = wait_provider_commit(seen)
    entries = call(
        "session.list_records", {"session_id": sid, "kind": "session-title/llm-request"}
    )["data"]
    assert len(entries) == 2, entries
    assert first["name"] in str(entries[-1]["messages"])
    assert "exactly, unchanged" in entries[-1]["system"]
    assert len(entries[-1]["message_ids"]) == 2
    messages = call("agent.list_messages", {"session_id": sid})["data"]
    assert any(m["role"] == "tool_result" for m in messages), messages
    assert not any("stable anchor" in str(m) for m in messages), messages
    call("commands.run", {"line": "/title rename RPC manual pin"})
    assert call("session.get", {"session_id": sid})["name"] == "RPC manual pin"
    before = len(entries)
    prompt_wait(sid, "manual title stays pinned")
    assert call("session.get", {"session_id": sid})["name"] == "RPC manual pin"
    entries = call(
        "session.list_records", {"session_id": sid, "kind": "session-title/llm-request"}
    )["data"]
    assert len(entries) == before
    seen = len(events)
    call("commands.run", {"line": "/title refresh"})
    refreshed, seen = wait_provider_commit(seen)
    assert refreshed["metadata"]["source"] == "provider"
    call("commands.run", {"line": "/title cancel"})
    call("shutdown")
    assert p.wait(timeout=10) == 0
    print(
        "session-title real RPC all-prompts provenance, anchor, manual pin and refresh passed"
    )
finally:
    if p.poll() is None:
        p.kill()
    p.wait()
