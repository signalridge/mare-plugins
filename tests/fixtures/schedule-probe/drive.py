"""Drive real RPC and wall clocks; product minimum interval remains sixty seconds."""
import json
import pathlib
import queue
import subprocess
import sys
import threading
import time

binary, cwd, report_path = sys.argv[1:]
process = subprocess.Popen([binary, "-C", cwd, "--rpc", "--yolo", "--no-session"], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
responses = queue.Queue()
errors = []
messages = []

def read():
    for line in process.stdout:
        message = json.loads(line)
        messages.append(message)
        responses.put(message)

def read_errors():
    for line in process.stderr:
        errors.append(line)

threading.Thread(target=read, daemon=True).start()
threading.Thread(target=read_errors, daemon=True).start()
serial = 0

def rpc(method, params=None):
    global serial
    serial += 1
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": serial, "method": method, "params": params or {}}) + "\n")
    process.stdin.flush()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            message = responses.get(timeout=1)
        except queue.Empty:
            if process.poll() is not None:
                raise AssertionError("Mare exited: " + "".join(errors))
            continue
        if message.get("id") == serial:
            assert "error" not in message, message
            return message.get("result")
    raise AssertionError(f"RPC timeout: {method}; {''.join(errors)}")

def report():
    try:
        return json.loads(pathlib.Path(report_path).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def tasks():
    rpc("commands.run", {"line": "/schedule-probe list"})
    return report()["tasks"]

def ui_text():
    return "\n".join(m.get("params", {}).get("text", "") for m in messages if m.get("method") == "ui.notify")

def wait_ends(count, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = report()
        if len(state.get("ends", [])) >= count:
            return state
        if process.poll() is not None:
            raise AssertionError("Mare exited: " + "".join(errors))
        time.sleep(0.2)
    raise AssertionError(f"Scheduled run did not finish: {report()}; {''.join(errors)}")

try:
    init = rpc("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
    assert "agent.prompt" in init["capabilities"]["methods"], init
    rpc("commands.run", {"line": "/schedule-probe contracts"})
    assert report().get("contracts"), report()
    rpc("commands.run", {"line": "/loop 59s rejected through the user command"})
    assert tasks() == []
    assert "at least one minute" in ui_text(), ui_text()
    started = time.monotonic()
    rpc("commands.run", {"line": "/loop 1m /lua error('scheduled slash must remain prompt')"})
    rpc("commands.run", {"line": "/loop Watch and choose the next delay"})
    initial = tasks()
    fixed_id = next(t["id"] for t in initial if t["mode"] == "fixed")
    adaptive_id = next(t["id"] for t in initial if t["mode"] == "adaptive")
    rpc("commands.run", {"line": f"/loop pause {fixed_id}"})
    assert next(t for t in tasks() if t["id"] == fixed_id)["status"] == "paused"
    rpc("commands.run", {"line": f"/loop resume {fixed_id}"})
    rpc("commands.run", {"line": "/loop list"})
    assert "delay=60000ms" in ui_text() and "adaptive" in ui_text(), ui_text()
    # At least two completed fixed runs and two complete adaptive runs, including real model tools.
    while time.monotonic() - started < 170:
        state = report()
        current_tasks = state.get("tasks", [])
        if len(state.get("ends", [])) >= 4 and any(t.get("delay_reason", "").startswith("Observed unchanged") for t in current_tasks):
            break
        if process.poll() is not None:
            raise AssertionError("Mare exited: " + "".join(errors))
        time.sleep(0.2)
    else:
        raise AssertionError(f"Two repetitions did not finish: {report()}; {''.join(errors)}")
    state = report()
    assert all(not e.get("error") for e in state["ends"]), state
    assert state["tool_errors"] >= 4 and state["accepted_intervals"] >= 1 and state.get("proxy_submit_ok"), state
    assert any(call["delay_ms"] == 59999 for call in state["calls"]), state
    assert any(call["delay_ms"] == 60000 and call["task_id"] == adaptive_id for call in state["calls"]), state
    assert state.get("proxy_submit_task") == adaptive_id, state
    fixed = [r for r in state["requests"] if "scheduled slash must remain prompt" in r["text"]]
    adaptive = [r for r in state["requests"] if "Watch and choose the next delay" in r["text"]]
    # Adaptive has one tool and one answer request per run. Compare distinct turn identities.
    first_by_turn = {}
    for request in adaptive:
        first_by_turn.setdefault(request["turn"], request["at"])
    assert len(fixed) >= 2 and len(first_by_turn) >= 2, state
    assert fixed[1]["at"] - fixed[0]["at"] >= 60000, fixed
    times = list(first_by_turn.values())
    assert times[1] - times[0] >= 60000, times
    assert time.monotonic() - started >= 120, "Product interval was shortened"
    for task_id in [fixed_id, adaptive_id]:
        rpc("commands.run", {"line": f"/loop stop {task_id}"})
    assert tasks() == []
    before_failure = len(report()["ends"])
    rpc("commands.run", {"line": "/loop 1m FAIL_ONCE"})
    error_id = tasks()[0]["id"]
    failed = wait_ends(before_failure + 1)
    assert failed["ends"][-1].get("error"), failed
    assert tasks()[0]["status"] == "paused"
    rpc("commands.run", {"line": "/loop list"})
    assert "schedule fixture failure" in ui_text(), ui_text()
    rpc("commands.run", {"line": f"/loop resume {error_id}"})
    recovered = wait_ends(before_failure + 2)
    assert not recovered["ends"][-1].get("error"), recovered
    rpc("commands.run", {"line": f"/loop stop {error_id}"})
    assert tasks() == []
    rpc("commands.run", {"line": "/loop 1m pending before session change"})
    rpc("session.create")
    assert tasks() == [], report()
    rpc("shutdown")
    process.wait(timeout=10)
    assert process.returncode == 0, "".join(errors)
except BaseException:
    print("Mare stderr:\n" + "".join(errors), file=sys.stderr)
    raise
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
