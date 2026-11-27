"""A child's session-search caller identity is the transcript the parent's host issued for it.

Runs on its own (before the UI and RPC drivers) so that no earlier failure hides it. The parent
side is what the parent observes when it spawns the child (mare.subagent.get(session_id).session_id and
mare.subagent.identity(session_id), written by the probe's /history-child); the child side is what
the child VM reports as its own session (ctx.agent:activity().session_id, which session-search's
caller_id() uses), captured from the child's request/build.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

work = sys.argv[1]
proc = subprocess.Popen(
    [os.environ["MARE_BIN"], "-C", work, "--yolo", "--rpc"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
)
next_id = 0


def result(method, params):
    global next_id
    next_id += 1
    proc.stdin.write(
        json.dumps(
            {"jsonrpc": "2.0", "id": next_id, "method": method, "params": params}
        )
        + "\n"
    )
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise AssertionError(proc.stderr.read())
        msg = json.loads(line)
        if msg.get("id") == next_id:
            assert "error" not in msg, msg
            return msg["result"]


def captures():
    return [
        json.loads(line)
        for line in Path(os.environ["HISTORY_CAPTURE"]).read_text(encoding="utf-8").splitlines()
    ]


try:
    result("initialize", {"protocol_version": "3.0"})
    result("session.load", {"session_id": "history-tools"})
    before = len(captures())
    result("commands.run", {"line": "/history-child"})
    report = json.loads(Path(os.environ["HISTORY_CHILD_REPORT"]).read_text(encoding="utf-8"))
    assert not report.get("error"), report
    observed = report["parent_observed"]
    child_id = observed["child_session_id"]
    # a saved, writable parent: the host creates the child transcript and assigns its identity;
    # the forged child_session_id/parent_session spawn options are ignored
    assert isinstance(child_id, str) and child_id and child_id != "forged-child", (
        observed
    )
    binding = observed["binding"]
    assert binding and binding["subagent_id"] == child_id, observed
    assert binding["parent_session_id"] == "history-tools", observed
    child_requests = [c for c in captures()[before:] if c["mode"] == "child"]
    assert child_requests, captures()[before:]
    caller_ids = {c["caller_id"] for c in child_requests}
    assert caller_ids == {child_id}, (caller_ids, child_requests, observed)
    traces = {
        provider: result(
            "query.call",
            {
                "operation": "session.trace",
                "provider": provider,
                "arguments": {"session_id": "history-tools"},
            },
        )
        for provider in ("live-sessions", "persisted-sessions")
    }
    # the parent's trace lists the host-issued transcript, from either provider
    for family in traces.values():
        assert any(n["session"]["session_id"] == child_id for n in family["descendants"]), (
            child_id,
            traces,
        )
    result("shutdown", {})
finally:
    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
print("session-search child identity: parent-observed transcript in the parent's trace; child caller id matches it")
