"""Installed title consumer over owned queues, crash recovery, readonly and real child VMs."""

import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

binary, work, script = sys.argv[1:]
Path(script).write_text(
    json.dumps([{"text": "parent response " * 8, "delay_ms": 20}] * 12),
    encoding="utf-8",
)


class Rpc:
    def __init__(self, *args, info="primary"):
        self.info = Path(os.environ["TITLE_RESULT"] + "." + info)
        self.proc = subprocess.Popen(
            [binary, "-C", work, "--rpc", "--yolo", *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ, TITLE_CUSTOM="sources", TITLE_INFO=str(self.info)),
            encoding="utf-8",
        )
        self.serial = 0
        self.pending = {}
        self.events = []
        self.incoming = queue.Queue()

        def _reader():
            for line in self.proc.stdout:
                self.incoming.put(json.loads(line))
            self.incoming.put(None)

        threading.Thread(target=_reader, daemon=True).start()
        init = self.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
        self.session_id = (init.get("session") or {}).get("session_id")
        if self.session_id:
            self.subscribe(self.session_id)

    def subscribe(self, sid):
        self.call(
            "events.subscribe",
            {
                "session_id": sid,
                "include": ["session-title/*", "turn/*", "item/*", "status/*", "session/*", "agent/*"],
            },
        )

    def send(self, method, params=None):
        self.serial += 1
        self.proc.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": self.serial,
                    "method": method,
                    "params": params or {},
                }
            )
            + "\n"
        )
        self.proc.stdin.flush()
        return self.serial

    def _read_message(self, timeout=20):
        try:
            message = self.incoming.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError(f"RPC timeout; stderr={self.proc.stderr.read()}") from None
        assert message is not None, self.proc.stderr.read()
        if message.get("method") == "event":
            self.events.append(message["params"])
        elif message.get("method") == "ui.select" and "id" in message:
            items = message["params"]["items"]
            index = next(
                i
                for i, item in enumerate(items)
                if item["label"] == "View read-only"
            )
            self.proc.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": {"index": index},
                    }
                )
                + "\n"
            )
            self.proc.stdin.flush()
        elif "id" in message:
            self.pending[message["id"]] = message
        return message

    def take(self, ident):
        deadline = time.monotonic() + 25
        while ident not in self.pending:
            left = deadline - time.monotonic()
            assert left > 0, f"timed out waiting for reply {ident}"
            self._read_message(timeout=left)
        message = self.pending.pop(ident)
        assert "error" not in message, message
        return message["result"]

    def call(self, method, params=None):
        return self.take(self.send(method, params))

    def prompt_wait(self, content):
        started = self.call("agent.prompt", {"session_id": self.session_id, "input": content})
        return self.call("agent.wait", {"session_id": self.session_id, "turn_id": started["turn_id"]})

    def wait_event(self, kind, start=0, predicate=None):
        deadline = time.monotonic() + 20
        index = start
        while True:
            while index < len(self.events):
                ev = self.events[index]
                index += 1
                if ev.get("type") == kind and (predicate is None or predicate(ev["data"])):
                    return ev["data"], index
            left = deadline - time.monotonic()
            assert left > 0, f"timed out waiting for event {kind}"
            self._read_message(timeout=left)

    def facts(self):
        self.call("commands.run", {"line": "/title-test-info"})
        return json.loads(self.info.read_text(encoding="utf-8"))

    def audits(self):
        return self.call(
            "session.list_records",
            {"session_id": self.session_id, "kind": "title-test/inputs"},
        )["data"]

    def idle(self):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if not self.call("agent.get", {"session_id": self.session_id})["busy"]:
                return
            self._read_message(timeout=min(0.5, deadline - time.monotonic()))
        raise AssertionError("agent never settled")

    def close(self, crash=False):
        if self.proc.poll() is None:
            if crash:
                self.proc.kill()
            else:
                self.call("shutdown")
        self.proc.wait(timeout=10)


clients = []
try:
    busy = Rpc("--session-id", "title-busy-sources")
    clients.append(busy)
    seen = len(busy.events)
    started = busy.call("agent.prompt", {"session_id": busy.session_id, "input": "human parent text"})
    _, seen = busy.wait_event("turn/started", seen)
    busy.call("commands.run", {"line": "/title-test-queue"})
    busy.call("agent.wait", {"session_id": busy.session_id, "turn_id": started["turn_id"]})
    busy.idle()
    # Sources mode commits "Sources title" on the second prompt's provider run (after recording title-test/inputs).
    _, seen = busy.wait_event(
        "session-title/changed",
        seen,
        lambda d: (d["state"].get("metadata") or {}).get("source") == "provider"
        and len((d["state"].get("metadata") or {}).get("message_ids") or []) == 0
        and len(busy.audits()) > 0
        and len(busy.audits()[-1]["messages"]) == 2,
    )
    audits = busy.audits()
    assert [m["text"] for m in audits[-1]["messages"]] == [
        "human parent text",
        "user queued text",
    ], audits
    messages = busy.call("agent.list_messages", {"session_id": busy.session_id})["data"]
    for source in ("peer", "user"):
        queued = [
            m
            for m in messages
            if m.get("_input_id")
            and m.get("source") == source
            and m.get("content")
            and m["content"][0].get("text") == f"{source} queued text"
        ]
        assert queued and queued[0]["content"][1]["type"] == "file", messages
        assert queued[0]["content"][2]["type"] == "image", messages
    assert any(m.get("notification") for m in messages), messages
    # This uses the current public transient child VM. It does not claim durable A2 recovery.
    busy.call("commands.run", {"line": "/title-test-child"})
    children = busy.call(
        "session.list_records", {"session_id": busy.session_id, "kind": "title-test/child"}
    )["data"]
    assert children and children[-1]["text"], children
    assert not any(
        e["name"] in ("session/named", "session-title/changed") or e.get("purpose") == "title"
        for e in children[-1]["events"]
    ), children
    assert any(
        e["name"] == "title-test/child-ready" and e.get("has_title")
        for e in children[-1]["events"]
    ), children
    parent = busy.facts()["info"]
    before = Path(parent["path"]).read_bytes()
    readonly = Rpc(info="readonly")
    loaded = readonly.call("session.load", {"path": parent["path"], "subscribe": True})
    readonly.session_id = loaded["session_id"]
    readonly.subscribe(readonly.session_id)
    clients.append(readonly)
    assert readonly.facts()["info"]["readonly"] is True
    count = len(readonly.audits())
    readonly.prompt_wait("readonly human must not retitle")
    readonly.call("commands.run", {"line": "/title refresh"})
    readonly.idle()
    assert len(readonly.audits()) == count
    readonly.close()
    assert Path(parent["path"]).read_bytes() == before
    busy.close()

    seed = Rpc("--session-id", "title-crash-sources")
    clients.append(seed)
    seed.prompt_wait("human seed text")
    seed.idle()
    seed.call("commands.run", {"line": "/title-test-queue"})
    queued = seed.facts()["queue"]["data"]
    assert [e["text"] for e in queued] == ["peer queued text", "user queued text"], queued
    assert [e["lane"] for e in queued] == ["follow_up", "follow_up"], queued
    seed.close(crash=True)
    restored = Rpc("--resume", "title-crash-sources", info="restored")
    clients.append(restored)
    queue_state = restored.facts()["queue"]["data"]
    assert [e["text"] for e in queue_state] == ["peer queued text", "user queued text"], queue_state
    assert [e["input_id"] for e in queue_state] == [e["input_id"] for e in queued], queue_state
    assert queue_state[0]["content"][1]["text"] == "FILE BODY MUST NOT TITLE"
    seen = len(restored.events)
    restored.prompt_wait("human resume text")
    restored.idle()
    restored.wait_event(
        "session-title/changed",
        seen,
        lambda d: (d["state"].get("metadata") or {}).get("source") == "provider"
        and len(restored.audits()) > 0
        and len(restored.audits()[-1]["messages"]) == 3,
    )
    audits = restored.audits()
    assert [m["text"] for m in audits[-1]["messages"]] == [
        "human seed text",
        "human resume text",
        "user queued text",
    ], audits
    restored.close()

    # Normal RPC prompt with file attachments uses canonical input_content (skips attachment-only, excludes file body).
    attach_file = Path(work) / "rpc-attachment.txt"
    attach_file.write_text("RPC ATTACHMENT BODY MUST NOT TITLE\n", encoding="utf-8")
    rpc_attach = Rpc("--session-id", "title-rpc-attachments")
    clients.append(rpc_attach)
    rpc_attach.prompt_wait([{"type": "file", "path": "rpc-attachment.txt"}])
    rpc_attach.idle()
    assert rpc_attach.call("session.get", {"session_id": rpc_attach.session_id}).get("name") is None
    assert len(rpc_attach.audits()) == 0
    seen = len(rpc_attach.events)
    rpc_attach.prompt_wait(
        [
            {"type": "text", "text": "human rpc attachment prompt"},
            {"type": "file", "path": "rpc-attachment.txt"},
        ]
    )
    rpc_attach.idle()
    rpc_attach.wait_event(
        "session-title/changed",
        seen,
        lambda d: (d["state"].get("metadata") or {}).get("source") == "provider"
        and len(rpc_attach.audits()) > 0,
    )
    attach_audits = rpc_attach.audits()
    assert [m["text"] for m in attach_audits[-1]["messages"]] == [
        "human rpc attachment prompt"
    ], attach_audits
    attach_msgs = rpc_attach.call("agent.list_messages", {"session_id": rpc_attach.session_id})["data"]
    user_attach = [
        m
        for m in attach_msgs
        if m.get("role") == "user"
        and m.get("content")
        and m["content"][0].get("text") == "human rpc attachment prompt"
    ]
    assert (
        user_attach
        and user_attach[0]["content"][1]["type"] in ("file", "mention")
        and user_attach[0]["content"][1]["path"] == "rpc-attachment.txt"
    ), attach_msgs
    rpc_attach.close()
    print(
        "session-title busy peer/human/file/image/notification, crash recovery, readonly and real child VM passed"
    )
finally:
    for client in clients:
        if client.proc.poll() is None:
            client.proc.kill()
        client.proc.wait()
