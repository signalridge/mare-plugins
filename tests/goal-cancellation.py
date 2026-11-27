#!/usr/bin/env python3
"""Real RPC/provider workflows for automatic/human cancellation and plugin lifetime."""
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

BIN, WORK, ROOT = sys.argv[1:]
SLOW = {"text": "slow " * 1000, "delay_ms": 10}
PAUSE = {"tool_calls": [{"name": "update_goal", "arguments": {"goal_id": "__goal__", "revision": 1, "status": "paused"}}]}


class Client:
    def __init__(self, case, script):
        path = Path(ROOT) / f"cancel-{case}.json"
        path.write_text(json.dumps(script), encoding="utf-8")
        self.process = subprocess.Popen(
            [BIN, "-C", WORK, "--rpc", "--yolo"], env=dict(os.environ, MARE_FAUX_SCRIPT=str(path)),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8",
        )
        self.lines = queue.Queue()
        self.events = []
        self.started_order = []
        self.started_seen = set()
        self.waited_ids = set()
        self.completed_ids = set()
        self.ident = 0
        def read():
            for line in self.process.stdout:
                self.lines.put(json.loads(line))
            self.lines.put(None)
        threading.Thread(target=read, daemon=True).start()
        init = self.call("initialize", {"protocol_version": "3.0"})
        self.methods = set((init.get("capabilities") or {}).get("methods") or [])
        self.owner = self.call("session.create", {})
        self.session_id = self.owner["session_id"]
        self.call(
            "events.subscribe",
            {
                "session_id": self.session_id,
                "include": ["item/*", "turn/*", "agent/*", "goal-probe/*"],
            },
        )

    def _record_event(self, ev):
        self.events.append(ev)
        kind = ev.get("type")
        data = ev.get("data") or {}
        tid = data.get("turn_id")
        if kind == "turn/started" and tid and tid not in self.started_seen:
            self.started_seen.add(tid)
            self.started_order.append(tid)
        elif kind == "turn/completed" and tid:
            self.completed_ids.add(tid)

    def call(self, method, params):
        self.ident += 1
        wanted = self.ident
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": wanted, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        while True:
            value = self.lines.get(timeout=15)
            assert value is not None, "RPC closed unexpectedly"
            if value.get("method") == "event":
                self._record_event(value["params"])
            if value.get("id") == wanted:
                assert "error" not in value, value
                return value.get("result")

    def goal(self):
        rows = self.call("session.list_records", {"kind": "goal/state", "session_id": self.session_id})["data"]
        return rows[-1]["goal"]

    def sid(self):
        return self.call("status.get", {})["session"]["session_id"]

    def busy(self):
        return self.call("agent.get", {"session_id": self.session_id})["busy"]

    def prompt_wait(self, text):
        started = self.call("agent.prompt", {"session_id": self.session_id, "input": text})
        tid = started.get("turn_id")
        if tid and tid not in self.started_seen:
            self.started_seen.add(tid)
            self.started_order.append(tid)
        res = self.call("agent.wait", {"session_id": self.session_id, "turn_id": tid})
        if tid:
            self.waited_ids.add(tid)
        return res

    def messages(self):
        return self.call("agent.list_messages", {"session_id": self.session_id})["data"]

    def wait(self, predicate):
        deadline = time.monotonic() + 30
        while True:
            self.call("status.get", {})
            if predicate():
                return
            assert time.monotonic() < deadline, self.events[-8:]
            time.sleep(0.01)

    def streamed(self):
        return any(event["type"] == "item/delta" for event in self.events)

    def wait_settled(self, min_turns=1):
        deadline = time.monotonic() + 30
        while True:
            next_tid = next((tid for tid in self.started_order if tid not in self.waited_ids), None)
            if next_tid is None:
                state = self.call("agent.get", {"session_id": self.session_id})
                active_tid = state.get("turn_id") if state.get("busy") else None
                if active_tid and active_tid not in self.started_seen:
                    self.started_seen.add(active_tid)
                    self.started_order.append(active_tid)
                next_tid = next((tid for tid in self.started_order if tid not in self.waited_ids), None)
                if next_tid is None:
                    if not state.get("busy") and len(self.waited_ids) >= min_turns:
                        return
                    assert time.monotonic() < deadline, self.events[-8:]
                    try:
                        value = self.lines.get(timeout=0.02)
                    except queue.Empty:
                        continue
                    assert value is not None, "RPC closed unexpectedly"
                    if value.get("method") == "event":
                        self._record_event(value["params"])
                    continue
            self.call("agent.wait", {"session_id": self.session_id, "turn_id": next_tid})
            self.waited_ids.add(next_tid)
            while next_tid not in self.completed_ids:
                assert time.monotonic() < deadline, self.events[-8:]
                value = self.lines.get(timeout=min(1.0, max(0.05, deadline - time.monotonic())))
                assert value is not None, "RPC closed unexpectedly"
                if value.get("method") == "event":
                    self._record_event(value["params"])

    def completed_turns(self):
        return len([event for event in self.events if event["type"] == "turn/completed"])

    def close(self):
        try:
            self.call("shutdown", {})
            self.process.wait(timeout=10)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait()
        stderr = self.process.stderr.read()
        if sys.exc_info()[0] is not None:
            print(stderr,file=sys.stderr)
        assert "dispose hook" not in stderr, stderr


skipped = []


def skip_cap(name):
    if name not in skipped:
        skipped.append(name)


for cause in ["user", "parent", "hook", "disposed"]:
    client = Client(cause, [SLOW])
    try:
        client.call("commands.run", {"line": "/goal explicit cancellation fixture"})
        client.wait(client.streamed)
        client.call("agent.cancel", {"session_id": client.session_id, "reason": cause})
        client.wait_settled()
        goal = client.goal()
        assert goal["rounds_started"] == 1
        ended = [event["data"] for event in client.events if event["type"] == "turn/completed"][-1]
        assert ended["termination_reason"] == "interrupted", ended
        if "cancellation_cause" in ended:
            assert ended["cancellation_cause"] == cause, ended
            assert goal["status"] == ("active" if cause == "disposed" else "paused"), (cause, goal)
        else:
            assert goal["status"] == "paused", (cause, goal)
            skip_cap("turn.completed.cancellation_cause")
    finally:
        client.close()

client = Client("unrelated", [SLOW,PAUSE,{"text":"continued goal explicitly paused"}])
try:
    client.call("commands.run", {"line": "/plan on"})
    client.call("commands.run", {"line": "/goal pending goal during unrelated work"})
    client.call("agent.prompt", {"session_id": client.session_id, "input": "ordinary unrelated human work"})
    client.wait(client.streamed)
    client.call("agent.cancel", {"session_id": client.session_id})
    client.wait_settled()
    goal = client.goal()
    assert goal["status"] == "active" and goal["rounds_started"] == 0, goal
    client.call("commands.run", {"line": "/plan off"})
    assert not client.busy()
    client.prompt_wait("Continue this active goal, then explicitly pause it with the model tool")
    assert client.goal()["status"]=="paused" and client.goal()["rounds_started"]==0
finally:
    client.close()

client = Client("model-pause", [PAUSE, {"text": "normal model pause closing reply"}])
try:
    client.call("commands.run", {"line": "/goal explicitly pause this fixture via the model tool"})
    client.wait_settled()
    assert client.goal()["status"] == "paused"
    ended = [event["data"] for event in client.events if event["type"] == "turn/completed"][-1]
    assert ended["termination_reason"] == "completed" and "cancellation_cause" not in ended, ended
finally:
    client.close()

client = Client("host-pause", [SLOW, PAUSE, {"text": "resumed goal paused normally"}])
try:
    client.call("commands.run", {"line": "/goal host control fixture"})
    client.wait(client.streamed)
    client.call("commands.run", {"line": "/goal pause"})
    client.call("commands.run", {"line": "/goal resume"})
    client.wait_settled(min_turns=2)
    goal = client.goal()
    assert goal["status"] == "paused" and goal["rounds_started"] == 2 and goal["audit_rounds"] == 1, goal
finally:
    client.close()

def probe_enqueue(c, params):
    return c.call("commands.run", {"line": "/goal-probe-enqueue " + json.dumps(params)})["result"]


def probe_resume(c, params):
    return c.call("commands.run", {"line": "/goal-probe-resume " + json.dumps(params)})["result"]


client = Client("retained-foreground", [SLOW, {"text": "foreground B completed exactly once"}])
try:
    client.call("commands.run", {"line": "/goal keep concurrent foreground input"})
    client.wait(client.streamed)
    receipt = probe_enqueue(client, {
        "expected": {"session_id": client.session_id},
        "content": [{"type": "text", "text": "human B retained once"},
                    {"type": "image", "data": "AA==", "mime": "image/png"},
                    {"type": "file", "path": "B.txt", "text": "B file fact"}],
        "inputContext": {"timezone": "Europe/London"}, "source": "goal",
    })
    assert receipt["status"] == "queued" and receipt["durable"], receipt
    client.call("commands.run", {"line": "/goal pause"})
    client.call("commands.run", {"line": "/goal resume"})
    client.wait_settled(min_turns=2)
    goal = client.goal()
    assert goal["status"] == "paused" and goal["rounds_started"] == 1, goal
    starts = [e["data"] for e in client.events if e["type"] == "turn/started"]
    assert len(starts) == 2 and starts[0]["turn_id"] != starts[1]["turn_id"], starts
    messages = client.messages()
    human = [m for m in messages if m.get("role") == "user" and "human B retained once" in str(m)]
    assert len(human) == 1, messages
    assert "B.txt" in str(human) and "image/png" in str(human), human
    assert human[0]["input_id"] == receipt["input_id"] and human[0]["source"] == "goal", human
    assert human[0]["input_context"]["timezone"] == "Europe/London", human
    assert not client.busy()
finally:
    client.close()

for default_cancel in [False, True]:
    client = Client("default-clear" if default_cancel else "resource-priority", [SLOW, {"text": "explicit foreground B"}])
    try:
        client.call("commands.run", {"line": "/goal queued input boundary"})
        client.wait(client.streamed)
        owner = {"session_id": client.session_id}
        receipt = probe_enqueue(client, {"expected": owner, "text": "boundary B"})
        assert receipt["status"] == "queued" and receipt["durable"], receipt
        if default_cancel:
            client.call("agent.cancel", {"session_id": client.session_id})
        else:
            client.call("commands.run", {"line": "/goal pause"})
        client.wait_settled()
        if not default_cancel:
            client.call("commands.run", {"line": "/goal rounds 1"})
            client.call("commands.run", {"line": "/goal resume"})
            assert not client.busy()
            assert client.goal()["rounds_started"] == 1
        resumed = probe_resume(client, {"expected": owner})
        assert resumed["status"] == ("empty" if default_cancel else "started"), resumed
        if not default_cancel:
            assert resumed["input_id"] == receipt["input_id"], resumed
            client.wait_settled(min_turns=2)
    finally:
        client.close()

client = Client("command-references", [PAUSE, {"text": "references received and goal paused"}])
try:
    outcome = client.call("commands.run", {
        "line": "/goal canonical reference objective",
        "input": {
            "content": [{"type": "text", "text": "/goal canonical reference objective"},
                        {"type": "file", "path": "goal-notes.txt", "text": "goal reference file fact"},
                        {"type": "image", "data": "AA==", "mime": "image/png"},
                        {"type": "text", "text": "trailing reference fact"}],
            "input_context": {"timezone": "Asia/Tokyo"},
        },
    })
    client.wait_settled()
    goal = client.goal()
    assert goal["objective"] == "canonical reference objective" and goal["status"] == "paused", (outcome, goal)
    assert goal["rounds_started"] == 0 and goal.get("stop_reason") != "references-pending", goal
    messages = client.messages()
    refs = [m for m in messages if m.get("role") == "user" and "goal-notes.txt" in str(m)]
    assert len(refs) == 1 and "trailing reference fact" in str(refs) and "image/png" in str(refs), messages
    assert refs[0]["input_context"]["timezone"] == "Asia/Tokyo", refs
    rejected_reply = client.call("commands.run", {
        "line": "/goal resume",
        "input": {
            "content": [{"type": "text", "text": "/goal resume"},
                        {"type": "file", "path": "unused.txt", "text": "must stay draft"}],
        },
    })
    rejected = rejected_reply["result"]
    assert rejected["status"] == "rejected" and "do not consume attachments" in rejected["reason"], rejected_reply
    assert client.goal()["status"] == "paused" and not client.busy()
    assert not any("unused.txt" in str(m) for m in client.messages()), client.messages()
    resubmitted = client.call("commands.run", {
        "line": "/goal edit canonical reference objective",
        "input": {
            "content": [{"type": "text", "text": "/goal edit canonical reference objective"},
                        {"type": "file", "path": "unused.txt", "text": "must stay draft"}],
        },
    })
    assert "error" not in resubmitted, resubmitted
    client.wait_settled(min_turns=2)
    assert client.goal()["status"] == "paused" and not client.busy(), client.goal()
    assert any("unused.txt" in str(m) for m in client.messages()), client.messages()
finally:
    client.close()

client=Client("active-edit",[SLOW,PAUSE,{"text":"edited goal paused normally"}])
try:
    client.call("commands.run",{"line":"/goal original objective before active edit"})
    client.wait(client.streamed)
    client.call("commands.run",{"line":"/goal edit revised objective during active round"})
    client.wait_settled(min_turns=2)
    goal=client.goal()
    assert goal["status"]=="paused" and goal["objective"]=="revised objective during active round" and goal["rounds_started"]==2,goal
    ended=[event["data"] for event in client.events if event["type"]=="turn/completed"]
    assert ended[0]["termination_reason"] == "interrupted" and ended[1]["termination_reason"] == "completed", ended
    if "cancellation_cause" in ended[0]:
        assert ended[0]["cancellation_cause"] == "parent", ended
    else:
        skip_cap("turn.completed.cancellation_cause")
finally:
    client.close()

client=Client("human-edit",[SLOW,{"text":"edited human plan reply"}])
try:
    client.call("commands.run",{"line":"/plan on"})
    client.call("commands.run",{"line":"/goal objective before human plan edit"})
    client.call("agent.prompt",{"session_id":client.session_id,"input":"investigate the goal while remaining in plan mode"})
    client.wait(client.streamed)
    client.call("commands.run",{"line":"/goal edit objective updated during human plan work"})
    client.wait_settled()
    goal=client.goal()
    assert goal["objective"]=="objective updated during human plan work" and goal["rounds_started"]==0
    assert goal["tokens_used"]==0 and goal["time_used_seconds"]==0,goal
    messages=client.messages()
    assert "The saved goal objective changed" in str(messages)
finally:
    client.close()

client = Client("reload", [PAUSE, {"text": "explicitly resumed reloaded goal paused"}])
try:
    client.call("events.subscribe", {"session_id": client.session_id, "include": ["goal-probe/*", "turn/*", "agent/*"]})
    client.call("commands.run", {"line": "/plan on"})
    client.call("commands.run", {"line": "/goal reload an idle active goal"})
    client.events.clear()
    client.started_order.clear()
    client.started_seen.clear()
    client.waited_ids.clear()
    client.completed_ids.clear()
    client.call("commands.run", {"line": "/reload goal"})
    client.wait(
        lambda: isinstance(
            (client.call("agent.get", {"session_id": client.session_id}).get("activity") or {})
            .get("extra", {})
            .get("goal"),
            dict,
        )
    )
    assert client.goal()["status"] == "active"
    client.call("commands.run", {"line": "/plan off"})
    assert not any(event["type"] == "turn/started" for event in client.events), "reload silently rearmed continuation"
    client.call("commands.run", {"line": "/goal resume"})
    client.wait_settled()
    goal = client.goal()
    assert goal["status"] == "paused" and goal["rounds_started"] == 1 and goal["audit_rounds"] == 1, goal
finally:
    client.close()
print("mare-plugins: goal user/parent/hook/disposed, unrelated work, model pause, host pause/resume and idle reload workflows passed")
if skipped:
    print("SKIPPED[capability=" + ",".join(skipped) + "] goal cancellation/enqueue checks require core extensions")
    sys.exit(77)
