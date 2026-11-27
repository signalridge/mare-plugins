#!/usr/bin/env python3
"""Drive the installed lifecycle fixture through public RPC cancellation and real child reap."""
import os
import sys

if not hasattr(os, "mkfifo"):
    print("SKIPPED[capability=posix.fifo] POSIX FIFO driver")
    sys.exit(77)

import importlib.util
import json
import pathlib
import select
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hooks_processes import assert_reaped, host_processes

spec = importlib.util.spec_from_file_location("rpc_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pty", "rpc_client.py"))
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)
work = pathlib.Path(os.environ["HOOK_EVENTS_WORK"])
pidfile = work / "stop.pid"
pidfile.unlink(missing_ok=True)
fifo_path = work / "stop.entered.fifo"
fifo_path.unlink(missing_ok=True)
os.mkfifo(fifo_path)
fifo_fd = os.open(fifo_path, os.O_RDWR)
compact_fifo_path = work / "compact.start.fifo"
compact_fifo_path.unlink(missing_ok=True)
os.mkfifo(compact_fifo_path)
compact_fifo_fd = os.open(compact_fifo_path, os.O_RDWR)
env = dict(
    os.environ,
    HOOK_STOP_MODE="wait",
    HOOK_DIALECT="codex",
    HOOK_STOP_FIFO=str(fifo_path),
    HOOK_COMPACT_FIFO=str(compact_fifo_path),
)
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    started = client.call("agent.prompt", {"session_id": sid, "input": "wait inside Stop"})
    ready, _, _ = select.select([fifo_fd], [], [], 5)
    assert ready, "Stop script was not reached"
    os.read(fifo_fd, 1)
    python_pids = host_processes(client.p.pid, int(pidfile.read_text(encoding="utf-8")))
    before = time.monotonic()
    cancel_res = client.call("agent.cancel", {"session_id": sid, "turn_id": started["turn_id"]})
    assert "removed" in cancel_res, cancel_res
    while not any(event.get("type")=="turn/completed" and event.get("turn_id")==started["turn_id"] for event in client.events):
        client.dispatch(client.read())
    assert time.monotonic() - before < 5, "abort waited for the ten-second hook deadline"
    assert_reaped(python_pids)
    events = [json.loads(line) for line in (work / "events.jsonl").read_text(encoding="utf-8").splitlines()]
    stop = [event for event in events if event["hook_event_name"] == "Stop"][-1]
    assert stop["turn_id"] == started["turn_id"], (stop, started)
    assert stop["stop_hook_active"] is False
    (work / "allow-stop").write_text("allow", encoding="utf-8")
    for index in range(6):
        s = client.call("agent.prompt", {"session_id": sid, "input": f"conversation before compact {index}"})
        client.call("agent.wait", {"session_id": sid, "turn_id": s["turn_id"]})
    compact = client.call("compact.run", {"session_id": sid})
    assert compact.get("status") == "compacted", compact
    ready, _, _ = select.select([compact_fifo_fd], [], [], 10)
    assert ready, "actual compact did not publish SessionStart(compact)"
    os.read(compact_fifo_fd, 1)
    events = [json.loads(line) for line in (work / "events.jsonl").read_text(encoding="utf-8").splitlines()]
    assert any(event["hook_event_name"] == "SessionStart" and event["source"] == "compact" for event in events), events
    after_s = client.call("agent.prompt", {"session_id": sid, "input": "after actual compact"})
    client.call("agent.wait", {"session_id": sid, "turn_id": after_s["turn_id"]})
    sid = client.call("status.get")["session"]["session_id"]
    history = client.call("agent.list_messages", {"session_id": sid})["data"]
    assert any(message.get("context_disclosure", {}).get("metadata", {}).get("source")=="compact" and message.get("notification") for message in history), history
finally:
    os.close(compact_fifo_fd)
    compact_fifo_path.unlink(missing_ok=True)
    os.close(fifo_fd)
    fifo_path.unlink(missing_ok=True)
    (work / "allow-stop").unlink(missing_ok=True)
    client.call("shutdown")
    client.p.wait(timeout=10)
print("hooks lifecycle RPC: actual turn identity, Stop cancellation/reap and real compact source disclosure passed")
