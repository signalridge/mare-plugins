#!/usr/bin/env python3
"""Protocol 3.0 RPC cancellation driver for plugins/toolbelt."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hooks_processes import is_pid_alive


def main() -> int:
    bin_path, work_dir, script_path, pid_file, ready_file = sys.argv[1:6]
    proc = subprocess.Popen(
        [bin_path, "-C", work_dir, "--rpc", "--yolo"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=dict(os.environ, MARE_FAUX_SCRIPT=script_path),
        encoding="utf-8",
    )

    msg_queue: queue.Queue[dict | None] = queue.Queue()
    events: list[dict] = []
    stderr_lines: list[str] = []

    def read_stdout() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if "id" not in msg and "method" in msg:
                events.append(msg)
            msg_queue.put(msg)
        msg_queue.put(None)

    def read_stderr() -> None:
        assert proc.stderr is not None
        stderr_lines.extend(proc.stderr.readlines())

    threading.Thread(target=read_stdout, daemon=True).start()
    threading.Thread(target=read_stderr, daemon=True).start()

    seq = 0

    def call(method: str, params: dict | None = None, timeout: float = 20.0) -> dict:
        nonlocal seq
        seq += 1
        req_id = seq
        assert proc.stdin is not None
        proc.stdin.write(
            json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
            + "\n"
        )
        proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            rem = max(0.05, deadline - time.monotonic())
            try:
                msg = msg_queue.get(timeout=rem)
            except queue.Empty as exc:
                raise AssertionError(
                    f"RPC {method} timed out; stderr={''.join(stderr_lines)}"
                ) from exc
            assert msg is not None, f"RPC closed early; stderr={''.join(stderr_lines)}"
            if msg.get("id") == req_id and "method" not in msg:
                assert "error" not in msg, f"RPC {method} failed: {msg}"
                return msg.get("result") or {}

    try:
        init_res = call("initialize", {"protocol_version": "3.0"})
        methods = (init_res.get("capabilities") or {}).get("methods") or []
        assert "agent.prompt" in methods and "agent.cancel" in methods, init_res

        status = call("status.get", {})
        sid = status["session"]["session_id"]

        started = call("agent.prompt", {"session_id": sid, "input": "hang toolbelt call"})
        turn_id = started["turn_id"]

        ready_path = Path(ready_file)
        pid_path = Path(pid_file)
        deadline = time.monotonic() + 15.0
        while not ready_path.exists() or not pid_path.exists() or not pid_path.read_text(encoding="utf-8").strip():
            assert time.monotonic() < deadline, (
                f"hanging tool child never became ready; events={events} stderr={''.join(stderr_lines)}"
            )
            time.sleep(0.02)

        pids = [int(p) for p in pid_path.read_text(encoding="utf-8").split() if p.strip()]
        assert pids, "expected at least one child PID"
        for pid in pids:
            assert is_pid_alive(pid), f"expected process {pid} to exist while running"

        call("agent.cancel", {"session_id": sid, "turn_id": turn_id})
        waited = call("agent.wait", {"session_id": sid, "turn_id": turn_id}, timeout=20.0)

        assert waited.get("status") == "cancelled" or waited.get("turn_cancelled") is True, waited

        # Confirm the child process (and any sub-child) is actually gone.
        reap_deadline = time.monotonic() + 5.0
        while time.monotonic() < reap_deadline:
            if all(not is_pid_alive(pid) for pid in pids):
                break
            time.sleep(0.02)

        still_alive = [pid for pid in pids if is_pid_alive(pid)]
        assert not still_alive, f"child processes survived cancellation: {still_alive}"

        # Also check tool call result recorded as cancelled in events or agent.list_messages.
        msgs = call("agent.list_messages", {"session_id": sid})
        tool_cancelled = False
        for ev in events:
            data = ev.get("params") or {}
            if ev.get("method") == "event" and data.get("type") == "item/completed":
                item = (data.get("data") or {}).get("item") or {}
                res = item.get("result") or {}
                if res.get("cancelled") is True:
                    tool_cancelled = True
        if not tool_cancelled and "cancelled" in json.dumps(msgs.get("data") or []):
            tool_cancelled = True
        assert tool_cancelled, f"expected cancelled tool outcome; events={events} msgs={msgs}"

        call("shutdown", {})
        proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
