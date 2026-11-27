"""Actual todo user workflow through the public RPC protocol and faux provider."""

import json
import queue
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

binary, work, script_file = sys.argv[1:]
script_file = Path(script_file)


def write_script(steps):
    script_file.write_text(json.dumps(steps), encoding="utf-8")


def update(items, explanation=None):
    args = {"todos": [{"content": text, "status": status} for text, status in items]}
    if explanation is not None:
        args["explanation"] = explanation
    return {"tool_calls": [{"name": "todo_write", "arguments": args}]}


class Client:
    def __init__(self, *args):
        self.p = subprocess.Popen(
            [binary, "-C", work, "--yolo", "--rpc", *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        self.inbox = queue.Queue()
        self.serial = 0
        self.events, self.dialogs, self.notices = [], [], []
        self.choose = None
        threading.Thread(target=self.read, daemon=True).start()
        init_res = self.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
        methods = (init_res.get("capabilities") or {}).get("methods") or []
        assert "agent.get" in methods, init_res

    def read(self):
        for line in self.p.stdout:
            self.inbox.put(json.loads(line))
        self.inbox.put(None)

    def send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def call(self, method, params, expect_error=False):
        self.serial += 1
        ident = self.serial
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            msg = self.inbox.get(timeout=45)
            assert msg is not None, self.p.stderr.read()
            if msg.get("method") == "ui.select":
                self.dialogs.append(msg["params"])
                # Closing the viewer must preserve the list.
                index = self.choose(msg["params"]) if self.choose else None
                self.send(
                    {"jsonrpc": "2.0", "id": msg["id"], "result": {"index": index}}
                )
            elif msg.get("method") == "ui.notify":
                self.notices.append(msg["params"])
            elif msg.get("method") == "event":
                self.events.append(msg["params"])
            elif msg.get("id") == ident:
                if expect_error:
                    assert "error" in msg, msg
                    return msg["error"]
                assert "error" not in msg, msg
                return msg["result"]

    def sid(self):
        return self.call("status.get", {})["session"]["session_id"]

    def prompt(self, text, wait=True):
        sid = self.sid()
        started = self.call("agent.prompt", {"session_id": sid, "input": text})
        if wait:
            return self.call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})
        return started

    def messages(self):
        return self.call("agent.list_messages", {"session_id": self.sid()})["data"]

    def projection(self):
        activity = self.call("agent.get", {"session_id": self.sid()})["activity"]
        assert "todo" in activity["extra"], activity
        assert not activity.get("extra_errors", {}).get("todo"), activity
        return activity["extra"]["todo"]

    def show(self):
        before = len(self.dialogs)
        self.call("commands.run", {"line": "/todos"})
        assert len(self.dialogs) == before + 1
        return self.dialogs[-1]

    def close(self):
        try:
            self.call("shutdown", {})
        finally:
            self.p.stdin.close()
            try:
                self.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()


first = [
    ("\u00a0alpha 世界\u3000", "in_progress"),
    ("beta", "pending"),
    ("done", "completed"),
]
second = [("done", "completed"), ("alpha 世界", "completed"), ("delta", "pending")]
write_script(
    [
        update(first, "Initial plan"),
        update(second, "Requirements changed"),
        update([("   ", "pending")]),
        update([("duplicate", "pending"), (" duplicate ", "completed")]),
        update(
            [
                ("unexpected parallel one", "in_progress"),
                ("unexpected parallel two", "in_progress"),
            ]
        ),
        {"text": "finished workflow"},
    ]
)
c = Client("--session-id", "todo-rpc")
try:
    c.prompt("Track the multi-step task", wait=True)
    ends = [e for e in c.events if e["type"] == "item/completed" and (e.get("data") or {}).get("item", {}).get("type") == "tool_call"]
    assert len(ends) == 5, ends
    raw = json.dumps(ends, ensure_ascii=False)
    assert (
        "Requirements changed" in raw
        and "todos[0].content must be a non-empty string" in raw
        and "todos[1].content duplicates" in raw
        and "at most one task may be in_progress (got 2)" in raw
    ), raw
    # Actual persisted tool messages include structured historical snapshots/diffs.
    messages = c.messages()
    encoded = json.dumps(messages, ensure_ascii=False)
    assert (
        "previous_status" in encoded
        and "moved" in encoded
        and "Requirements changed" in encoded
    ), encoded
    dialog = c.show()
    assert [item["label"] for item in dialog["items"]] == [
        "[x] done",
        "[x] alpha 世界",
        "[ ] delta",
    ], dialog
    assert [item["detail"] for item in dialog["items"]] == [
        "completed",
        "completed",
        "pending",
    ]
    assert (
        c.show()["items"] == dialog["items"]
    )  # cancelling the first dialog changed nothing
    for action in ("expand", "collapse", "toggle"):
        c.call("commands.run", {"line": "/todos " + action})
    c.call("commands.run", {"line": "/todos invalid"})
    assert "Usage: /todos" in json.dumps(c.notices), c.notices
finally:
    c.close()

# Restore and view before a new user prompt; the prior suite only checked clearing.
write_script([{"text": "new work without a checklist"}])
c = Client("--resume", "todo-rpc")
try:
    assert [item["label"] for item in c.show()["items"]] == [
        "[x] done",
        "[x] alpha 世界",
        "[ ] delta",
    ]
    c.prompt("A different user task", wait=True)
    assert c.show()["items"] == []
finally:
    c.close()

# The parallel option must affect real schema-backed execution, not only a stub.
write_script(
    [
        update([("parallel one", "in_progress"), ("parallel two", "in_progress")]),
        {"text": "parallel done"},
    ]
)
c = Client(
    "--session-id",
    "todo-parallel",
    "--set",
    "plugins.todo.allow_parallel_in_progress=true",
)
try:
    c.prompt("Work concurrently", wait=True)
    assert len(c.show()["items"]) == 2
finally:
    c.close()
# Tightening the write policy does not invalidate a previously saved parallel list.
c = Client("--resume", "todo-parallel")
try:
    assert len(c.show()["items"]) == 2
finally:
    c.close()

# Independent real writes distinguish reorder, each removal, and explicit clear.
sequence = [
    [("one", "pending"), ("two", "completed"), ("three", "pending")],
    [("three", "pending"), ("one", "pending"), ("two", "completed")],
    [("three", "pending"), ("two", "completed")],
    [("three", "pending")],
    [],
]
write_script([*(update(items) for items in sequence), {"text": "sequence complete"}])
c = Client("--session-id", "todo-sequence")


def tool_results(value):
    if isinstance(value, dict):
        if (
            value.get("role") == "tool_result"
            and value.get("tool_name") == "todo_write"
        ):
            yield value
        for item in value.values():
            yield from tool_results(item)
    elif isinstance(value, list):
        for item in value:
            yield from tool_results(item)


try:
    assert "No checklist has been written" in json.dumps(c.show())
    assert c.projection() is None
    c.prompt("Reorder and remove each task", wait=True)
    results = list(tool_results(c.messages()))
    assert len(results) == len(sequence), results
    for result, expected in zip(results, sequence):
        assert [
            (t["content"], t["status"]) for t in result["details"]["todos"]
        ] == expected
    assert results[0]["details"]["diff"]["baseline"] == "initial"
    assert results[0]["details"]["diff"]["counts"]["added"] == 3
    assert results[1]["details"]["diff"]["counts"]["updated"] == 3
    for result in results[2:]:
        assert result["details"]["diff"]["counts"]["removed"] == 1
    assert c.show()["items"] == [] and "explicitly cleared" in json.dumps(c.show())
    assert c.projection() == []
    systems = [
        json.loads(line)["system"]
        for line in script_file.with_name("requests.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert any('"todos":null' in system for system in systems), systems[-1]
    assert '"todos":[]' in systems[-1], systems[-1]
finally:
    c.close()
write_script([{"text": "new work"}])
c = Client("--resume", "todo-sequence")
try:
    assert "explicitly cleared" in json.dumps(c.show())
    assert c.projection() == []
    c.prompt("New task resets explicit empty checklist", wait=True)
    assert "No checklist has been written" in json.dumps(c.show())
    assert c.projection() is None
finally:
    c.close()

# Stop at a real tool-result boundary, reopen, then /continue without a user reset.
write_script([update([("before recovery", "pending"), ("retained", "completed")])])
seed = subprocess.run(
    [
        binary,
        "-C",
        work,
        "--yolo",
        "-p",
        "--max-turns",
        "1",
        "--session-id",
        "todo-diff-recovery",
        "Create an interrupted task",
    ],
    check=False,
    capture_output=True,
    text=True,
    timeout=20,
    encoding="utf-8",
)
assert seed.returncode == 4, (seed.stdout, seed.stderr)
write_script(
    [
        update([("retained", "completed"), ("after recovery", "pending")]),
        {"text": "recovery complete"},
    ]
)
c = Client("--resume", "todo-diff-recovery")
try:
    assert c.show()["items"][0]["label"] == "[ ] before recovery"
    assert c.projection()[0]["content"] == "before recovery"
    c.call("commands.run", {"line": "/continue"})
    deadline = time.monotonic() + 10
    while not any(e["type"] == "turn/completed" for e in c.events):
        c.call("agent.get", {"session_id": c.sid()})
        assert time.monotonic() < deadline, c.events
        time.sleep(0.02)
    last = list(tool_results(c.messages()))[-1]["details"]
    assert (
        last["diff"]["baseline"] == "previous"
        and last["diff"]["counts"]["removed"] == 1
    ), last
    assert [item["label"] for item in c.show()["items"]] == [
        "[x] retained",
        "[ ] after recovery",
    ]
finally:
    c.close()

# Public plan_mode provider is the real sibling plugin, exercised through commands.
write_script(
    [
        update([("not allowed while planning", "pending")]),
        {"text": "planning done"},
        update([("allowed after leaving plan mode", "pending")]),
        {"text": "execution done"},
    ]
)
c = Client("--no-session")
try:
    c.call("commands.run", {"line": "/plan on"})
    c.prompt("Plan the task", wait=True)
    assert c.show()["items"] == []
    events_json = json.dumps(c.events)
    assert "todo_write is a checklist tool and cannot run in plan mode" in events_json, c.events
    c.call("commands.run", {"line": "/plan off"})
    c.prompt("Execute the task", wait=True)
    assert c.show()["items"][0]["label"] == "[ ] allowed after leaving plan mode"
finally:
    c.close()

# Interrupt a genuine provider stream before its queued todo call can execute.
write_script(
    [
        {
            "text": "slow " * 100,
            "delay_ms": 100,
            "tool_calls": update([("must never appear", "completed")])["tool_calls"],
        }
    ]
)
c = Client("--no-session")
try:
    c.prompt("Work that will be cancelled", wait=False)
    c.call("agent.cancel", {"session_id": c.sid()})
    deadline = time.monotonic() + 10
    while True:
        state = c.call("agent.get", {"session_id": c.sid()})
        if not state.get("busy", False):
            break
        assert time.monotonic() < deadline, state
        time.sleep(0.05)
    assert c.show()["items"] == []
    assert not any(
        e["type"] == "item/completed" and (e.get("data") or {}).get("item", {}).get("type") == "tool_call"
        for e in c.events
    ), c.events
finally:
    c.close()
# A real background job completion wakes the agent as a notification, rather
# than a new user task; the current checklist must survive that separate run.
notify_gate = script_file.parent / "todo-notify.gate"
notify_gate.unlink(missing_ok=True)
write_script(
    [
        update([("survives background notification", "in_progress")]),
        {
            "tool_calls": [
                {
                    "name": "bash",
                    "arguments": {
                        "command": (
                            f"while [ ! -f {shlex.quote(str(notify_gate))} ]; do sleep 0.05; done; "
                            "printf todo-notification-job"
                        ),
                        "run_in_background": True,
                    },
                }
            ]
        },
        {"text": "initial task waiting"},
        {"text": "notification acknowledged"},
    ]
)
c = Client("--no-session")
try:
    c.prompt("Track work while a job finishes", wait=True)
    notify_gate.write_text("go\n", encoding="utf-8")
    deadline = time.monotonic() + 10
    while not any(
        e["type"] == "turn/started" and e.get("data", {}).get("trigger") == "notification"
        for e in c.events
    ):
        c.call("agent.get", {"session_id": c.sid()})
        assert time.monotonic() < deadline, c.events
        time.sleep(0.02)
    while sum(e["type"] == "turn/completed" for e in c.events) < 2:
        c.call("agent.get", {"session_id": c.sid()})
        assert time.monotonic() < deadline, c.events
        time.sleep(0.02)
    assert c.projection() == [
        {"content": "survives background notification", "status": "in_progress"}
    ]
    assert c.show()["items"][0]["label"] == "[~] survives background notification"
finally:
    c.close()

# Busy human input is queued within the current run by the shared admission
# service. Neither steering nor a follow-up begins a fresh checklist owner.
write_script(
    [
        update([("survives queued human input", "in_progress")]),
        {"text": "working " * 30, "delay_ms": 30},
        {"text": "steering considered"},
        {"text": "follow-up considered"},
        {"text": "busy prompt considered"},
        {"text": "fresh user work"},
    ]
)
c = Client("--no-session")
try:
    c.prompt("Start queued-input task", wait=False)
    deadline = time.monotonic() + 15
    expected = [{"content": "survives queued human input", "status": "in_progress"}]
    while c.projection() != expected:
        assert time.monotonic() < deadline, c.events
        time.sleep(0.02)
    sid = c.sid()
    assert c.call("agent.get", {"session_id": sid})["busy"]
    c.call("agent.steer", {"session_id": sid, "input": "Keep the current checklist while adjusting the task"})
    c.call("agent.prompt", {"session_id": sid, "input": "Then report the same checklist", "when_busy": "queue"})
    queued = c.call("agent.prompt", {"session_id": sid, "input": "Also retain the checklist"})
    assert queued.get("status") == "queued" and queued.get("input_id"), queued
    while c.call("agent.get", {"session_id": sid}).get("busy"):
        assert time.monotonic() < deadline, c.events
        time.sleep(0.02)
    assert c.projection() == expected
    turn_starts = [e for e in c.events if e["type"] == "turn/started"]
    assert len(turn_starts) == 1, c.events
    messages = c.messages()
    users = [m for m in messages if m["role"] == "user" and not m.get("notification")]
    assert len(users) == 4, users
    user_items = [
        e
        for e in c.events
        if e["type"] == "item/completed"
        and (e.get("data") or {}).get("item", {}).get("type") == "user_message"
        and not ((e.get("data") or {}).get("item", {}).get("message") or {}).get("notification")
    ]
    assert len(user_items) == 4, user_items
    assert all(e.get("turn_id") == turn_starts[0]["turn_id"] for e in user_items), user_items
    c.prompt("Begin a separate user task", wait=True)
    assert c.projection() is None
finally:
    c.close()

# A locked owner must require an explicit read-only/fork decision. Cancelling
# that decision must preserve both runtimes and the owner checklist.
write_script([update([("live owner's checklist", "pending")]), {"text": "owner idle"}])
owner = Client("--session-id", "todo-owner")
reader = None
try:
    owner.prompt("Create a durable checklist", wait=True)
    reader = Client()
    error = reader.call("session.load", {"session_id": "todo-owner"}, expect_error=True)
    assert (
        "session switch cancelled" in error["message"]
        or (error.get("data") or {}).get("code") in ("cancelled", "internal")
    ), error
    assert any(
        item["label"] == "View read-only"
        for dialog in reader.dialogs
        for item in dialog["items"]
    ), reader.dialogs
    assert reader.projection() is None
    assert owner.show()["items"][0]["label"] == "[ ] live owner's checklist"
finally:
    if reader:
        reader.close()
    owner.close()
print(
    "todo: real RPC null/[] projection, reorder/remove/clear, restored diffs, notification, busy prompt/steer/follow-up origins, plan-mode, abort and locked-session refusal passed"
)
