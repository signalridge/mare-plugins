"""Real public-provider error, timeout, cancellation and unloading behavior."""

import json
import os
import queue
import subprocess
import sys
import threading
import time

binary, work = sys.argv[1:]
for mode in ("none", "error", "timeout", "cancel", "dispose", "controls"):
    proc = subprocess.Popen(
        [binary, "-C", work, "--rpc", "--yolo"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=dict(os.environ, TITLE_CUSTOM=mode),
        encoding="utf-8",
    )
    serial = 0
    events = []
    incoming = queue.Queue()

    def _reader(proc=proc, incoming=incoming):
        for line in proc.stdout:
            incoming.put(json.loads(line))
        incoming.put(None)

    threading.Thread(target=_reader, daemon=True).start()

    def read_message(deadline, proc=proc, incoming=incoming):
        remaining = deadline - time.monotonic()
        assert remaining > 0, proc.stderr.read()
        try:
            item = incoming.get(timeout=remaining)
        except queue.Empty:
            raise AssertionError((mode, events)) from None
        assert item is not None, proc.stderr.read()
        return item

    def call(method, params=None, proc=proc, events=events, incoming=incoming):
        global serial
        serial += 1
        proc.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": serial,
                    "method": method,
                    "params": params or {},
                }
            )
            + "\n"
        )
        proc.stdin.flush()
        deadline = time.monotonic() + 25
        while True:
            message = read_message(deadline, proc, incoming)
            if message.get("method") == "event":
                events.append(message["params"])
            elif message.get("id") == serial:
                assert "error" not in message, message
                return message["result"]

    def wait_event(predicate, start=0, proc=proc, events=events, mode=mode, incoming=incoming):
        deadline = time.monotonic() + 10
        index = start
        while True:
            while index < len(events):
                ev = events[index]
                index += 1
                if ev.get("type") == "session-title/changed":
                    state = ev["data"]["state"]
                    if predicate(state):
                        return state, index
            message = read_message(deadline, proc, incoming)
            if message.get("method") == "event":
                events.append(message["params"])

    def wait_name_changed(source, start=0, proc=proc, events=events, mode=mode):
        return wait_event(
            lambda d: (d.get("metadata") or {}).get("source") == source,
            start=start,
            proc=proc,
            events=events,
            mode=mode,
        )

    def prompt_wait(sid, text):
        started = call("agent.prompt", {"session_id": sid, "input": text})
        return call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})

    def current_title_state(sid):
        info = call("session.get", {"session_id": sid})
        recs = call(
            "session.list_records", {"session_id": sid, "kind": "session-title/state"}
        )["data"]
        rev = info.get("name_revision", 0)
        match = next(
            (
                r
                for r in reversed(recs)
                if r.get("name") == info.get("name") and r.get("name_revision") == rev
            ),
            None,
        )
        return {
            "name": info.get("name"),
            "name_revision": rev,
            "metadata": match.get("metadata") if match else None,
        }

    try:
        init = call("initialize", {"protocol_version": "3.0"})
        sid = init["session"]["session_id"]
        call(
            "events.subscribe",
            {"session_id": sid, "include": ["session-title/*", "turn/*", "item/*", "status/*", "session/*"]},
        )
        seen = len(events)
        prompt_wait(sid, "fallback title for errors")
        if mode != "none":
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                entries = call(
                    "session.list_records", {"session_id": sid, "kind": "title-test/provider-start"}
                )["data"]
                if any(e.get("mode") == mode for e in entries):
                    break
                time.sleep(0.02)
            else:
                raise AssertionError("custom provider did not start")
        if mode == "controls":
            state, seen = wait_name_changed("provider", seen)
            name = state["name"]
            assert state["metadata"]["source"] == "provider", state
            assert "\x1b" not in name and "\x07" not in name and "\u202e" not in name
            assert len(name.encode()) <= 320
        elif mode == "cancel":
            call("commands.run", {"line": "/title rename Manual during generation"})
            wait_event(lambda d: d.get("name") == "Manual during generation", seen)
            prompt_wait(sid, "keep manual title after cancel")
            assert call("session.get", {"session_id": sid})["name"] == "Manual during generation"
        elif mode == "dispose":
            start = time.monotonic()
            call("commands.run", {"line": "/title-provider-remove"})
            assert time.monotonic() - start >= 0.08, (
                "provider removal returned before generation drained"
            )
            assert current_title_state(sid)["metadata"]["source"] == "fallback"
        elif mode in ("none", "error", "timeout"):
            state, seen = wait_name_changed("fallback", seen)
            assert state["name"] == "fallback title for errors", (mode, state)
            state = current_title_state(sid)
            assert state["name"] == "fallback title for errors", (mode, state)
            assert state["metadata"]["source"] == "fallback", (mode, state)
        call("shutdown")
        assert proc.wait(timeout=10) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
print(
    "session-title real no-provider, error, timeout, manual cancellation, disposer drain and UTF-8/control safety passed"
)
