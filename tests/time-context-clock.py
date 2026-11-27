#!/usr/bin/env python3
"""Drive real provider fallback/midnight, zone resume and workspace-cwd restoration."""
import json
import os
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def timeout(_signum, _frame):
    raise TimeoutError("clock RPC flow timed out")


if hasattr(signal, "SIGALRM"):
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(45)
binary, work, script = sys.argv[1:]
capture = Path(os.environ["TIME_CAPTURE"])
first = int(datetime(2026, 11, 14, 14, 59, tzinfo=timezone.utc).timestamp() * 1000)
second = first + 120_000


class Client:
    def __init__(self, zone, samples, resume=False):
        args = [binary, "-C", work, "--rpc", "--yolo"]
        args += ["--resume", "time-clock-flow"] if resume else ["--session-id", "time-clock-flow"]
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=dict(
                                            os.environ, TZ=zone, TIME_SAMPLE_SERIES=json.dumps(samples)), encoding="utf-8")
        self.ident = 0
        self.events = []
        self.init_res = self.call("initialize", {"protocol_version": "3.0"})

    def read(self):
        line = self.process.stdout.readline()
        assert line, self.process.stderr.read()
        value = json.loads(line)
        if value.get("method") == "event":
            self.events.append(value["params"])
        elif value.get("method") in ("workspace/opened", "workspace/failed"):
            self.events.append({"type":value["method"],"data":value.get("params",{})})
        return value

    def call(self, method, params):
        self.ident += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.ident,
                                            "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        while True:
            value = self.read()
            if value.get("id") == self.ident:
                assert "error" not in value, value
                return value.get("result")

    def prompt(self, text):
        sid = self.call("status.get", {})["session"]["session_id"]
        res = self.call(
            "commands.run",
            {
                "line": f"/time-facts {text}",
                "input": {
                    "content": [{"type": "text", "text": text}],
                    "input_context": {"timezone": "Asia/Tokyo"},
                },
            },
        )["result"]
        turn = self.call("agent.wait", {"session_id": sid, "turn_id": res["turn_id"]})
        assert not turn.get("error"), turn

    def close(self):
        self.call("shutdown", {})
        assert self.process.wait(timeout=10) == 0


def sent():
    return [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]


def state(request):
    return [message["context_disclosure"]["state"] for message in request["messages"]
            if message.get("context_disclosure", {}).get("namespace") == "time-context"][-1]


capture.write_text("", encoding="utf-8")
Path(script).write_text(json.dumps([
    {"error": "unknown model", "kind": "model_not_found", "retryable": False},
    {"tool_calls": [{"name": "time_probe", "arguments": {}}]},
    {"text": "midnight flow finished"},
]), encoding="utf-8")
client = Client("Asia/Tokyo", [first, second])
try:
    client.prompt("observe the clock across a read-only tool loop")
    requests = sent()
    assert len(requests) == 3, requests
    initial, fallback, midnight = map(state, requests)
    assert initial == fallback, "provider fallback sampled the clock twice"
    assert initial["host"]["local_date"] == "2026-11-14", initial
    assert midnight["host"]["local_date"] == "2026-11-15", midnight
    assert midnight["reason"] == "host-date"
    assert midnight["host"]["instant_ms"] - initial["host"]["instant_ms"] == 120_000
finally:
    client.close()

capture.write_text("", encoding="utf-8")
Path(script).write_text(json.dumps([{"text": "zone resumed"}, {"text": "cwd restored"}]), encoding="utf-8")
client = Client("Asia/Seoul", [second], resume=True)
try:
    client.prompt("resume the profile with a changed host zone")
    resumed = state(sent()[-1])
    assert resumed["host"]["timezone"] == "Asia/Seoul", resumed
    assert resumed["reason"] == "host-zone", resumed
    assert resumed["host"]["instant_ms"] == second
    new_work = str(Path(work).with_name("clock-new-workspace"))
    Path(new_work).mkdir()
    created = client.call("session.create", {"cwd": new_work})
    new_sid = created["session_id"]
    started = client.call("agent.prompt", {"session_id": new_sid, "input": "open a new session in a new cwd"})
    turn = client.call("agent.wait", {"session_id": new_sid, "turn_id": started["turn_id"]})
    assert not turn.get("error"), turn
    moved = state(sent()[-1])
    assert Path(moved["cwd"]).resolve() == Path(new_work).resolve(), (moved, new_work)
    assert moved["reason"] == "unknown", moved
    client.call("session.close", {"session_id": new_sid})
finally:
    client.close()
print("time-context real RPC midnight-before-interval, fallback, host-zone resume and session.create cwd passed")

# Public plugin configuration: canonical timezone and interval=0 must affect actual requests.
config = Path(os.environ["MARE_HOME"]) / "config/init.lua"
original = config.read_text(encoding="utf-8")
try:
    def run_configured_zone(input_zone):
        config.write_text(original.replace("mare.setup { ",
            'mare.setup { plugins = { ["time-context"] = { timezone = "{input_zone}", refresh_interval_ms = 0 } }, '.replace("{input_zone}", input_zone), 1), encoding="utf-8")
        capture.write_text("", encoding="utf-8")
        Path(script).write_text(json.dumps([
            {"tool_calls": [{"name": "time_probe", "arguments": {}}]}, {"text": "configured loop"},
        ]), encoding="utf-8")
        output = subprocess.run([binary, "-C", work, "-p", "--yolo", "configured clock"],
                                env=dict(os.environ, TZ="Asia/Tokyo", TIME_SAMPLE_SERIES=json.dumps([second])),
                                check=False, capture_output=True, text=True, timeout=15, encoding="utf-8")
        return output, sent() if output.returncode == 0 else []

    for canonical_zone in ("America/New_York", "America/Los_Angeles"):
        output, requests = run_configured_zone(canonical_zone)
        assert output.returncode == 0, output.stderr
        assert len(requests) == 2
        configured = state(requests[-1])
        assert configured["configured_zone"] == canonical_zone, configured
        assert configured["reason"] == "interval", configured
        assert configured["host"]["instant_ms"] == state(requests[0])["host"]["instant_ms"]
        assert configured["host"]["local_date"] != configured["request_date"]
    config.write_text(original.replace("mare.setup { ",
        'mare.setup { plugins = { ["time-context"] = { refresh_interval_ms = 0.5 } }, ', 1), encoding="utf-8")
    capture.write_text("", encoding="utf-8")
    output = subprocess.run([binary, "-C", work, "--strict-config", "-p", "--yolo", "invalid config must refuse"],
                            check=False, capture_output=True, text=True, timeout=15, encoding="utf-8")
    assert output.returncode == 2 and "refresh_interval_ms" in output.stderr, output
    assert capture.read_text(encoding="utf-8") == ""

    config.write_text(original.replace("mare.setup { ",
        'mare.setup { plugins = { ["time-context"] = { nonfatal_clock_read_errors = "yes" } }, ', 1), encoding="utf-8")
    capture.write_text("", encoding="utf-8")
    output = subprocess.run([binary, "-C", work, "--strict-config", "-p", "--yolo", "invalid nonfatal flag must refuse"],
                            check=False, capture_output=True, text=True, timeout=15, encoding="utf-8")
    assert output.returncode == 2 and "nonfatal_clock_read_errors" in output.stderr, output
    assert capture.read_text(encoding="utf-8") == ""

    # Default (nonfatal_clock_read_errors = false): out-of-range sample error must fail before provider.
    config.write_text(original, encoding="utf-8")
    capture.write_text("", encoding="utf-8")
    Path(script).write_text(json.dumps([{"text": "unreachable"}]), encoding="utf-8")
    output = subprocess.run([binary, "-C", work, "-p", "--yolo", "fatal clock error by default"],
                            env=dict(os.environ, TZ="Asia/Tokyo", TIME_SAMPLE_SERIES=json.dumps([999999999999999])),
                            check=False, capture_output=True, text=True, timeout=15, encoding="utf-8")
    assert output.returncode != 0 and "four-digit positive year" in output.stderr, output
    assert capture.read_text(encoding="utf-8") == ""

    # Opt-in nonfatal_clock_read_errors = true: deduplicated unavailable notice, recovery, and re-failure in RPC.
    config.write_text(original.replace("mare.setup { ",
        'mare.setup { plugins = { ["time-context"] = { nonfatal_clock_read_errors = true } }, ', 1), encoding="utf-8")
    capture.write_text("", encoding="utf-8")
    Path(script).write_text(json.dumps([
        {"tool_calls": [{"name": "time_probe", "arguments": {}}]},
        {"text": "unavailable turn finished"},
        {"text": "recovered turn finished"},
        {"text": "failed again turn finished"},
    ]), encoding="utf-8")
    nonfatal_client = Client.__new__(Client)
    nonfatal_client.process = subprocess.Popen(
        [binary, "-C", work, "--rpc", "--yolo", "--session-id", "time-clock-nonfatal"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=dict(os.environ, TZ="Asia/Tokyo", TIME_SAMPLE_SERIES=json.dumps([
            999999999999999, 999999999999999, second, 999999999999999,
        ])),
        encoding="utf-8",
    )
    nonfatal_client.ident = 0
    nonfatal_client.events = []
    nonfatal_client.call("initialize", {"protocol_version": "3.0"})
    try:
        nonfatal_client.prompt("turn 1: clock unavailable across tool loop")
        nonfatal_client.prompt("turn 2: clock recovered")
        nonfatal_client.prompt("turn 3: clock unavailable after recovery")
    finally:
        nonfatal_client.close()
    requests = sent()
    assert len(requests) == 4, requests
    disclosures_by_req = [
        [m["context_disclosure"] for m in req["messages"] if m.get("context_disclosure", {}).get("namespace") == "time-context"]
        for req in requests
    ]
    assert len(disclosures_by_req[0]) == 1 and disclosures_by_req[0][0]["state"]["status"] == "unavailable"
    assert len(disclosures_by_req[1]) == 1, "consecutive failure in same turn must deduplicate"
    unavailable_msg = next(m for m in requests[0]["messages"] if m.get("context_disclosure", {}).get("namespace") == "time-context")
    unavailable_text = "\n".join(part["text"] for part in unavailable_msg["content"] if part.get("type") == "text")
    assert 'status="unavailable"' in unavailable_text, unavailable_text
    assert "failed to read current time" in unavailable_text, unavailable_text
    assert "four-digit positive year" not in unavailable_text, unavailable_text
    assert len(disclosures_by_req[2]) == 2 and disclosures_by_req[2][-1]["state"]["reason"] == "recovered"
    assert len(disclosures_by_req[3]) == 3 and disclosures_by_req[3][-1]["state"]["status"] == "unavailable"
finally:
    config.write_text(original, encoding="utf-8")
print("time-context real headless configured timezone, every-step interval=0, nonfatal clock errors and invalid-config admission passed")
