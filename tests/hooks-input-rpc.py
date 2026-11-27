#!/usr/bin/env python3
"""Owned queued admission, policy veto/retry, canonical content and cancellation via RPC."""
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hooks_processes import assert_reaped, host_processes

spec = importlib.util.spec_from_file_location("rpc_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pty", "rpc_client.py"))
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)
work = Path(os.environ["HOOK_INPUT_WORK"])
metadata = Path(os.environ["HOOK_INPUT_META"])
requests = Path(os.environ["HOOK_INPUT_REQUESTS"])
allow = work / "input.allow"


def rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []


def settled(client, turn):
    while not any(event.get("type") == "turn/completed" and event.get("data", {}).get("turn_id") == turn for event in client.events):
        client.dispatch(client.read())


for mode in ("queue", "wait"):
    allow.unlink(missing_ok=True)
    for path in (metadata, requests, work / "hooks.jsonl", work / "input.pid"):
        path.unlink(missing_ok=True)
    fifo_path = work / "input.entered.fifo"
    fifo_path.unlink(missing_ok=True)
    extra_env = {"HOOK_DIALECT": "codex", "HOOK_INPUT_MODE": mode}
    fifo_fd = None
    if mode == "wait":
        if not hasattr(os, "mkfifo"):
            print("SKIPPED[capability=posix.fifo] POSIX FIFO driver")
            sys.exit(77)
        os.mkfifo(fifo_path)
        fifo_fd = os.open(fifo_path, os.O_RDWR)
        extra_env["HOOK_INPUT_FIFO"] = str(fifo_path)
    argv = [os.environ["MARE_BIN"], "--rpc", "--yolo"]
    if mode == "wait":
        argv.append("--no-session")
    client = rpc.Client(argv, dict(os.environ, **extra_env), work)
    try:
        initialized = client.call("initialize", {"protocol_version": "3.0"})
        caps = client.call("commands.run", {"line": "/hooks-input-caps"})["result"]
        assert caps["input_admission"] == 1, caps
        sid = initialized["session"]["session_id"]
        client.call("events.subscribe", {"session_id": sid, "include": ["turn/*", "status/*"]})
        if mode == "queue":
            owner = {"session_id": sid}
            first = client.call("commands.run", {"line": "/hooks-input-enqueue " + json.dumps({
                "owner": owner,
                "source": "user",
                "content": [
                    {"type": "text", "text": "QUEUED FIRST"},
                    {"type": "file", "path": str(work / "facts.txt"), "text": "FILE FACT"},
                ],
            })})["result"]
            second = client.call("commands.run", {"line": "/hooks-input-enqueue " + json.dumps({
                "owner": owner,
                "source": "peer",
                "text": "DENY QUEUED",
                "inputContext": {"timezone": "Asia/Tokyo"},
            })})["result"]
            assert first["status"] == second["status"] == "queued", (first, second)
            assert first["durable"] is True and second["durable"] is True, (first, second)
            assert not metadata.exists() and not (work / "hooks.jsonl").exists(), "enqueue was mistaken for consumption"
            started = client.call("commands.run", {"line": "/hooks-input-resume " + json.dumps({"owner": owner})})["result"]
            assert started["status"] == "started", started
            settled(client, started["turn_id"])
            assert not requests.exists(), "a later veto still permitted provider I/O"
            assert client.call("agent.get", {"session_id": sid})["queued"] == 2
            before = client.call("agent.list_messages", {"session_id": sid})["data"]
            assert not any(message.get("input_id") in (first["input_id"], second["input_id"]) for message in before), before
            allow.write_text("allow retry", encoding="utf-8")
            retried = client.call("commands.run", {"line": "/hooks-input-resume " + json.dumps({"owner": owner})})["result"]
            assert retried["status"] == "started", retried
            settled(client, retried["turn_id"])
            assert client.call("agent.get", {"session_id": sid})["queued"] == 0
            events = rows(metadata)
            assert [event["input_id"] for event in events] == [first["input_id"], second["input_id"], first["input_id"], second["input_id"]], events
            assert len({event["attempt_id"] for event in events}) == 4
            assert events[1]["source"] == "peer" and events[1]["input_context"] == {"timezone": "Asia/Tokyo"}
            assert "facts.txt" in json.dumps(events[0]["content"]), events
            hooks = rows(work / "hooks.jsonl")
            assert len(hooks) == 4 and hooks[0]["prompt"] == "QUEUED FIRST", hooks
            history = client.call("agent.list_messages", {"session_id": sid})["data"]
            accepted = [message for message in history if message.get("input_id") in (first["input_id"], second["input_id"])]
            assert len(accepted) == 2 and [message["input_attempt_id"] for message in accepted] == [event["attempt_id"] for event in events[2:]], history
            disclosures = [message for message in history if message.get("context_disclosure", {}).get("namespace") == "hooks.prompts"]
            assert len(disclosures) == 1 and disclosures[0]["notification"] is True
            assert [item["attempt_id"] for item in disclosures[0]["context_disclosure"]["metadata"]["inputs"]] == [event["attempt_id"] for event in events[2:]]
            assert len(rows(requests)) == 3, rows(requests)
        else:
            import select

            started = client.call("agent.prompt", {"session_id": sid, "input": "cancel pending input hook"})
            ready, _, _ = select.select([fifo_fd], [], [], 5)
            assert ready, "input hook did not start"
            os.read(fifo_fd, 1)
            pids = host_processes(client.p.pid, int((work / "input.pid").read_text(encoding="utf-8")))
            began = time.monotonic()
            assert client.call("agent.cancel", {"session_id": sid})
            settled(client, started["turn_id"])
            assert time.monotonic() - began < 5
            assert_reaped(pids)
            assert not requests.exists(), "cancelled input reached the provider"
            assert len(rows(metadata)) == 1
    finally:
        if fifo_fd is not None:
            os.close(fifo_fd)
            fifo_path.unlink(missing_ok=True)
        allow.unlink(missing_ok=True)
        client.call("shutdown")
        client.p.wait(timeout=10)
print("hooks input RPC: owned queue veto/retry, source facts, canonical content, disclosure and cancellation/reap passed")
