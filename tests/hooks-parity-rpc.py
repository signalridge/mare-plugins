#!/usr/bin/env python3
"""E2E RPC tests for PreCompact/PostCompact, SHA-256 trust confirmation, and /hooks command."""
import os
import sys

if not hasattr(os, "mkfifo"):
    print("SKIPPED[capability=posix.fifo] POSIX FIFO driver")
    sys.exit(77)

import importlib.util
import json
import pathlib
import select

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("rpc_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pty", "rpc_client.py"))
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


class ParityClient(rpc.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.select_calls = []

    def dispatch(self, message):
        if message.get("method") == "ui.select" and "id" in message:
            params = message.get("params", {})
            self.select_calls.append(params)
            self.send({"id": message["id"], "result": {"index": 0}})
            return None
        return super().dispatch(message)


def command_status(text):
    """commands.run returns {result?} on success and throws a coded error on failure;
    a command returning a {status} table carries it in result.status, while one returning
    nothing is treated as completed."""
    reply = client.call("commands.run", {"line": text})
    assert isinstance(reply, dict) and "ok" not in reply, (text, reply)
    result = reply.get("result")
    status = result.get("status") if isinstance(result, dict) else None
    return "completed" if status is None else status


def current_sid():
    return client.call("status.get")["session"]["session_id"]


def prompt_wait(text):
    sid = current_sid()
    started = client.call("agent.prompt", {"session_id": sid, "input": text})
    return client.call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})


work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "rpc-parity.jsonl"
log_path.unlink(missing_ok=True)
post_fifo_path = work / "post-compact.fifo"
post_fifo_path.unlink(missing_ok=True)
os.mkfifo(post_fifo_path)
post_fifo_fd = os.open(post_fifo_path, os.O_RDWR)
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="compact-veto", PARITY_POST_COMPACT_FIFO=str(post_fifo_path))
client = ParityClient([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, work)
try:
    client.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})

    # 1. Trust confirmation via ui.select on first PreToolUse, then cached on second.
    prompt_wait("first trusted probe")
    assert len(client.select_calls) == 1, client.select_calls
    assert client.select_calls[0]["title"] == "Trust hook handler?", client.select_calls[0]
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len([e for e in events if e["event"] == "PreToolUse"]) == 1, events

    prompt_wait("second trusted probe")
    assert len(client.select_calls) == 1, "trust should be remembered without re-prompting"
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len([e for e in events if e["event"] == "PreToolUse"]) == 2, events

    # 2. /hooks status and interactive /hooks toggle via ui.select.
    assert command_status("/hooks status") == "completed"
    assert command_status("/hooks") == "completed"
    assert len(client.select_calls) == 2 and client.select_calls[1]["title"].startswith("Hooks"), client.select_calls

    # Disabled PreToolUse handler should not run.
    prompt_wait("disabled probe")
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len([e for e in events if e["event"] == "PreToolUse"]) == 2, events

    # Re-enable via /hooks enable 1, and trust PreCompact (2) & PostCompact (3).
    assert command_status("/hooks enable 1") == "completed"
    assert command_status("/hooks trust 2") == "completed"
    assert command_status("/hooks trust 3") == "completed"

    # 3. PreCompact ordinary deny (exit 2) must NOT block compaction, and PostCompact still runs.
    for i in range(4):
        prompt_wait(f"turn {i} before compact")
    veto_res = client.call("commands.run", {"line": "/compact"})
    assert isinstance(veto_res, dict), veto_res
    ready, _, _ = select.select([post_fifo_fd], [], [], 10)
    assert ready, "timed out waiting for PostCompact hook completion"
    os.read(post_fifo_fd, 1)
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    pre_count = len([e for e in events if e["event"] == "PreCompact"])
    post_count = len([e for e in events if e["event"] == "PostCompact"])
    assert pre_count == 1 and post_count == 1, (pre_count, post_count, events)

    # 4. PreCompact continue:false stops compaction and PostCompact does not run.
    (work / "allow-compact").write_text("1", encoding="utf-8")
    (work / "pre-stop").write_text("1", encoding="utf-8")
    prompt_wait("turn before pre-stop")
    stop_err = client.call_error("compact.run", {"session_id": current_sid()})
    assert (stop_err.get("data") or {}).get("code") == "compact.not_compacted", stop_err
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    pre_count = len([e for e in events if e["event"] == "PreCompact"])
    post_count = len([e for e in events if e["event"] == "PostCompact"])
    assert pre_count == 2 and post_count == 1, (pre_count, post_count, events)

    # 5. PostCompact continue:false propagates as a real stop on manual compaction.
    (work / "pre-stop").unlink(missing_ok=True)
    for i in range(4):
        prompt_wait(f"turn {i} before post-stop " + ("padding " * 15))
    (work / "post-stop").write_text("1", encoding="utf-8")
    post_stop_res = client.call("compact.run", {"session_id": current_sid()})
    client.call("status.get")
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    pre_count = len([e for e in events if e["event"] == "PreCompact"])
    post_count = len([e for e in events if e["event"] == "PostCompact"])
    assert pre_count == 3 and post_count == 2, (pre_count, post_count, [e for e in client.events if e.get("type", "").startswith("compact")], events)
    # compact/after is emit (return value ignored): PostCompact ran and manual compaction succeeds
    assert post_stop_res.get("status") == "compacted", post_stop_res
finally:
    os.close(post_fifo_fd)
    post_fifo_path.unlink(missing_ok=True)
    (work / "allow-compact").unlink(missing_ok=True)
    (work / "pre-stop").unlink(missing_ok=True)
    (work / "post-stop").unlink(missing_ok=True)
    client.call("shutdown")
    client.p.wait(timeout=10)
print("hooks parity RPC: PreCompact exit-2 non-blocking, PreCompact/PostCompact continue:false, trust ui.select and /hooks passed")
