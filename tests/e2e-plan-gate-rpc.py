#!/usr/bin/env python3
"""Real JSON-RPC approval chain verification for plan-mode unconfined tool rules."""
import json
import os
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading

repo = pathlib.Path(__file__).resolve().parents[1]
binary = pathlib.Path(os.environ.get("MARE_BIN", repo.parent / "mare/target/debug/mare"))

PLAN_REASON = "This tool runs outside the local sandbox and may have side effects that plan mode cannot block"


def widget_text(node):
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return None
    parts = []
    if isinstance(node.get("text"), str):
        parts.append(node["text"])
    for key in ("spans", "lines", "children", "items"):
        val = node.get(key)
        if isinstance(val, list):
            for child in val:
                txt = widget_text(child)
                if txt:
                    parts.append(txt)
    for key in ("child", "left", "right"):
        if isinstance(node.get(key), dict):
            txt = widget_text(node[key])
            if txt:
                parts.append(txt)
    return "\n".join(parts) if parts else None


def prepare_sandbox(root, init_lua):
    package = root / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(repo / "mare-plugin.toml", package)
    for source in (repo / "plugins/plan-mode", repo / "tests/fixtures/plan-mode-probe"):
        shutil.copytree(source, package / "plugins" / source.name)

    def git(*args):
        subprocess.run(["git", "-C", str(package), *args], check=True, capture_output=True)

    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    config = root / "home/config"
    plugins_dir = config / "plugins"
    plugins_dir.mkdir(parents=True)
    (config / "init.lua").write_text(init_lua.format(package=package.as_uri()), encoding="utf-8")
    (plugins_dir / "gate-rpc-probe.lua").write_text(
        """local exec_count = 0
return {
\tname = "gate-rpc-probe",
\tinject = { "tools" },
\tapply = function(ctx)
\t\tctx.tools:register("mcp_probe", {
\t\t\tdescription = "Read-only unconfined probe tool",
\t\t\tside_effect = "read",
\t\t\tunconfined = true,
\t\t\tparameters = { type = "object", properties = {} },
\t\t\texecute = function()
\t\t\t\texec_count = exec_count + 1
\t\t\t\treturn "probe-ran:" .. tostring(exec_count)
\t\t\tend,
\t\t})
\tend,
}
""",
        encoding="utf-8",
    )


def open_rpc_session(root, init_lua, script_turns):
    prepare_sandbox(root, init_lua)
    script = root / "script.json"
    script.write_text(json.dumps(script_turns), encoding="utf-8")
    env = dict(
        os.environ,
        MARE_HOME=str(root / "home"),
        MARE_FAUX_SCRIPT=str(script),
        PLAN_CAPTURE=str(root / "capture.jsonl"),
    )
    subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
    stderr = (root / "stderr").open("w+")
    process = subprocess.Popen(
        [str(binary), "--rpc"],
        env=env,
        cwd=root,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=stderr,
        bufsize=0,
    )
    lines = queue.Queue()

    def _read_stdout():
        while True:
            line = process.stdout.readline()
            lines.put(line)
            if not line:
                break

    threading.Thread(target=_read_stdout, daemon=True).start()
    sequence = 0
    approvals = []
    tool_results = []
    plan_records = []
    plan_widgets = []
    pending_decisions = []

    def send(payload):
        process.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
        process.stdin.flush()

    def call(method, params):
        nonlocal sequence
        sequence += 1
        request_id = sequence
        send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            try:
                line = lines.get(timeout=45)
            except queue.Empty:
                raise AssertionError(f"RPC timeout for {method}")
            if not line:
                stderr.seek(0)
                raise AssertionError("RPC exited: " + stderr.read())
            message = json.loads(line)
            if "method" in message and "id" in message:
                if message["method"] == "approval.request":
                    approvals.append(message["params"])
                    decision = pending_decisions.pop(0) if pending_decisions else "deny"
                    result = {"decision": decision}
                else:
                    raise AssertionError(f"unexpected RPC request: {message!r}")
                send({"jsonrpc": "2.0", "id": message["id"], "result": result})
            elif message.get("method") == "ui.widget":
                wp = message.get("params") or {}
                if wp.get("widget_id") == "plan-mode":
                    text = wp.get("text")
                    if text is None and "node" in wp:
                        text = widget_text(wp.get("node"))
                    plan_widgets.append(text)
            elif message.get("method") == "event":
                ev = message.get("params") or {}
                if ev.get("type") == "item/completed":
                    item = (ev.get("data") or {}).get("item") or {}
                    if item.get("type") == "custom" and item.get("kind") == "plan-mode/state":
                        plan_records.append(item.get("data") or (item.get("entry") or {}).get("data") or {})
                    elif item.get("type") == "tool_call":
                        msg = item.get("message") or item.get("result") or {}
                        text = "\n".join(
                            c.get("text", "") for c in (msg.get("content") or []) if c.get("type") == "text"
                        )
                        tool_results.append(
                            {
                                "tool": item.get("name"),
                                "call_id": item.get("tool_call_id"),
                                "is_error": bool(msg.get("is_error") or msg.get("isError")),
                                "text": text,
                            }
                        )
            elif message.get("id") == request_id:
                assert "error" not in message, message
                return message.get("result")

    def plan_active():
        return bool(plan_widgets and plan_widgets[-1] and "PLAN" in plan_widgets[-1])

    def run_prompt(text, decisions=()):
        pending_decisions.extend(decisions)
        sid = call("status.get", {})["session"]["session_id"]
        started = call("agent.prompt", {"session_id": sid, "input": text})
        res = call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})
        assert res and res.get("status") != "failed" and not res.get("error"), res

    def close():
        try:
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()

    call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}})
    return call, plan_active, run_prompt, approvals, tool_results, plan_records, plan_widgets, close


def main():
    if not (binary.is_file() and os.access(binary, os.X_OK)):
        raise SystemExit(f"mare-plugins: executable not found: {binary} (set MARE_BIN)")

    # Scenario A: Positive allow_session cache baseline (plan off) -> still asks with PLAN_REASON when plan on
    turns_a = [
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "off-1"},
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "off-2-cached"},
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "on-deny"},
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "on-allow"},
    ]
    with tempfile.TemporaryDirectory(prefix="mare-plan-gate-rpc-sess-") as d1:
        call, plan_active, run_prompt, approvals, results, plan_records, plan_widgets, close = open_rpc_session(
            pathlib.Path(d1),
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
            turns_a,
        )
        try:
            assert not plan_active()
            run_prompt("off call 1", ["allow_session"])
            assert len(approvals) == 1 and approvals[0]["tool"] == "mcp_probe", approvals
            assert len(results) == 1 and results[0]["tool"] == "mcp_probe"
            assert results[0]["call_id"] == approvals[0]["tool_call_id"]
            assert not results[0]["is_error"] and results[0]["text"] == "probe-ran:1", results

            run_prompt("off call 2 (cached allow_session)")
            assert len(approvals) == 1, f"expected allow_session cache hit while plan off, got {approvals!r}"
            assert len(results) == 2 and results[1]["tool"] == "mcp_probe"
            assert not results[1]["is_error"] and results[1]["text"] == "probe-ran:2", results

            cmd_res = call("commands.run", {"line": "/plan on"})
            assert isinstance(cmd_res, dict), cmd_res
            assert plan_active(), f"expected plan mode active after /plan on: records={plan_records!r}, widgets={plan_widgets!r}"

            run_prompt("on call 3 (must still ask despite allow_session, deny)", ["deny"])
            assert len(approvals) == 2, f"expected 2nd approval under plan mode, got {approvals!r}"
            ap2 = approvals[1]
            assert ap2["tool"] == "mcp_probe" and PLAN_REASON in (ap2.get("reason") or ""), ap2
            assert len(results) == 3 and results[2]["tool"] == "mcp_probe"
            assert results[2]["call_id"] == ap2["tool_call_id"]
            assert results[2]["is_error"] and "probe-ran:" not in results[2]["text"], results[2]

            run_prompt("on call 4 (must still ask, allow executes)", ["allow"])
            assert len(approvals) == 3, f"expected 3rd approval under plan mode, got {approvals!r}"
            ap3 = approvals[2]
            assert ap3["tool"] == "mcp_probe" and PLAN_REASON in (ap3.get("reason") or ""), ap3
            assert len(results) == 4 and results[3]["tool"] == "mcp_probe"
            assert results[3]["call_id"] == ap3["tool_call_id"]
            assert not results[3]["is_error"] and results[3]["text"] == "probe-ran:3", results[3]
        finally:
            close()

    # Scenario B: Positive persistent allow rule baseline (plan off) -> still asks with PLAN_REASON when plan on
    turns_b = [
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "off-persistent"},
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "on-persistent-deny"},
    ]
    with tempfile.TemporaryDirectory(prefix="mare-plan-gate-rpc-allow-") as d2:
        call, plan_active, run_prompt, approvals, results, plan_records, plan_widgets, close = open_rpc_session(
            pathlib.Path(d2),
            (
                'mare.setup {{model="faux/echo"}}\n'
                'mare.plugins.add {{{{"test/plan",url="{package}"}}}}\n'
                'mare.plugin("permissions", {{ rules = {{ {{ tool = "mcp_probe", decision = "allow" }} }} }})\n'
            ),
            turns_b,
        )
        try:
            assert not plan_active()
            run_prompt("off call with persistent allow")
            assert len(approvals) == 0, f"expected persistent allow to auto-run while plan off, got {approvals!r}"
            assert len(results) == 1 and results[0]["tool"] == "mcp_probe"
            assert not results[0]["is_error"] and results[0]["text"] == "probe-ran:1", results[0]

            cmd_res = call("commands.run", {"line": "/plan on"})
            assert isinstance(cmd_res, dict), cmd_res
            assert plan_active()

            run_prompt("on call with persistent allow (must ask with PLAN_REASON)", ["deny"])
            assert len(approvals) == 1, f"expected 1 approval under plan mode, got {approvals!r}"
            ap = approvals[0]
            assert ap["tool"] == "mcp_probe" and PLAN_REASON in (ap.get("reason") or ""), ap
            assert len(results) == 2 and results[1]["tool"] == "mcp_probe"
            assert results[1]["call_id"] == ap["tool_call_id"]
            assert results[1]["is_error"] and "probe-ran:" not in results[1]["text"], results[1]
        finally:
            close()

    # Scenario C: Select allow_session WHILE plan mode is already active, then call again in same session -> must still ask
    turns_c = [
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "in-plan-allow-session-1"},
        {"tool_calls": [{"name": "mcp_probe", "arguments": {}}]},
        {"text": "in-plan-allow-session-2"},
    ]
    with tempfile.TemporaryDirectory(prefix="mare-plan-gate-rpc-inplan-") as d3:
        call, plan_active, run_prompt, approvals, results, plan_records, plan_widgets, close = open_rpc_session(
            pathlib.Path(d3),
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
            turns_c,
        )
        try:
            cmd_res = call("commands.run", {"line": "/plan on"})
            assert isinstance(cmd_res, dict), cmd_res
            assert plan_active()

            run_prompt("in-plan call 1 (select allow_session)", ["allow_session"])
            assert len(approvals) == 1
            ap1 = approvals[0]
            assert ap1["tool"] == "mcp_probe" and (
                PLAN_REASON in (ap1.get("reason") or "")
                or "not confined by the local sandbox" in (ap1.get("reason") or "")
            ), ap1
            assert len(results) == 1 and results[0]["call_id"] == ap1["tool_call_id"]
            assert not results[0]["is_error"] and results[0]["text"] == "probe-ran:1", results[0]

            run_prompt("in-plan call 2 (must still ask despite allow_session)", ["deny"])
            assert len(approvals) == 2, f"expected 2nd approval after in-plan allow_session, got {approvals!r}"
            ap2 = approvals[1]
            assert ap2["tool"] == "mcp_probe" and PLAN_REASON in (ap2.get("reason") or ""), ap2
            assert ap2["tool_call_id"] != ap1["tool_call_id"]
            assert len(results) == 2 and results[1]["call_id"] == ap2["tool_call_id"]
            assert results[1]["is_error"] and "probe-ran:" not in results[1]["text"], results[1]
        finally:
            close()

    print("mare-plugins: plan-mode RPC approval chain (allow_session + in-plan repeat + persistent allow) passed")


if __name__ == "__main__":
    main()
