#!/usr/bin/env python3
"""E2E matrix for codemode commands, UI rendering, resume, policy/cwd switches, and mid-call abort."""

import json
import os
import pathlib
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = os.environ.get(
    "MARE_BIN",
    str(ROOT.parent / "mare/target/debug/mare"),
)


class RpcClient:
    """Queue-backed JSON-RPC harness for non-blocking callback hold/cancel tests."""

    def __init__(self, argv, env, cwd):
        self.p = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=cwd,
            text=True,
            bufsize=1,
            encoding="utf-8",
        )
        self.next_id = 0
        self.session_id = None
        self.messages = queue.Queue()
        self.events = []
        self.notifies = []
        self.cancels = []
        self.statuses = []
        self.opened = []
        self.held_tools = []
        self.hold_tags = set()
        self.tool_names_by_reg = {}
        self._pending_tool_regs = {}
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.p.stdout:
            line = line.strip()
            if line:
                self.messages.put(json.loads(line))

    def send(self, msg):
        msg["jsonrpc"] = "2.0"
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def request(self, method, params=None):
        self.next_id += 1
        payload = dict(params or {})
        if method == "tools.register" and isinstance(payload.get("name"), str):
            self._pending_tool_regs[self.next_id] = payload["name"]
        if method.startswith("cells.") and "session_id" not in payload and self.session_id:
            payload["session_id"] = self.session_id
        self.send({"id": self.next_id, "method": method, "params": payload})
        return self.next_id

    def reply_tool(self, tool_msg, result):
        self.send({"id": tool_msg["id"], "result": result})

    def _handle_incoming(self, msg):
        method = msg.get("method")
        if method is None:
            return False
        if method == "event":
            ev = msg["params"]
            self.events.append(ev)
            if ev.get("type") == "status/changed":
                self.statuses.append(ev.get("data") or {})
        elif method == "ui.notify":
            self.notifies.append(msg["params"])
        elif method == "$/cancel_request":
            self.cancels.append(msg["params"])
        elif method == "status/changed":
            self.statuses.append(msg["params"])
        elif method == "workspace/opened":
            self.opened.append(msg["params"])
        elif method == "callback.call":
            payload = msg["params"].get("arguments") or {}
            args = payload.get("args") or {}
            name = self.tool_names_by_reg.get(msg["params"].get("registration_id"))
            if args.get("tag") in self.hold_tags or name == "host_hold":
                self.held_tools.append(msg)
            else:
                self.reply_tool(msg, {"content": "host_ok"})
        elif method in ("ui.select", "ui.input", "ui.confirm"):
            self.send({"id": msg["id"], "result": {}})
        return True

    def pump_until(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while not predicate():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("timed out waiting on RPC predicate")
            msg = self.messages.get(timeout=remaining)
            self._handle_incoming(msg)

    def wait(self, rid, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for RPC response id={rid}")
            msg = self.messages.get(timeout=remaining)
            if not self._handle_incoming(msg) and msg.get("id") == rid:
                reg_name = self._pending_tool_regs.pop(rid, None)
                if "error" in msg:
                    raise RuntimeError(f"rpc error: {msg['error']}")
                res = msg["result"]
                if reg_name and isinstance(res, dict) and isinstance(res.get("registration_id"), str):
                    self.tool_names_by_reg[res["registration_id"]] = reg_name
                return res

    def call(self, method, params=None, timeout=20):
        res = self.wait(self.request(method, params), timeout=timeout)
        if isinstance(res, dict):
            sid = res.get("session_id") or (res.get("session") or {}).get("session_id")
            if isinstance(sid, str):
                self.session_id = sid
        return res

    def prompt_wait(self, text):
        started = self.call("agent.prompt", {"session_id": self.session_id, "input": text})
        return self.call("agent.wait", {"session_id": self.session_id, "turn_id": started["turn_id"]})

    def _pid_alive(self, pid):
        if os.name == "nt":
            import ctypes
            k = ctypes.windll.kernel32
            h = k.OpenProcess(0x1000, False, int(pid))
            if not h:
                return False
            try:
                code = ctypes.c_ulong()
                return bool(k.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259
            finally:
                k.CloseHandle(h)
        if pathlib.Path("/proc").is_dir():
            return pathlib.Path(f"/proc/{pid}").exists()
        try:
            os.kill(int(pid), 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def worker_pids(self):
        children = pathlib.Path(f"/proc/{self.p.pid}/task/{self.p.pid}/children")
        if children.exists():
            pids = set()
            for pid in children.read_text(encoding="utf-8").split():
                try:
                    if "__lua-vm-worker" in pathlib.Path(f"/proc/{pid}/cmdline").read_text(encoding="utf-8"):
                        pids.add(int(pid))
                except FileNotFoundError:
                    pass
            return pids
        if os.name == "nt":
            return set()
        out = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True, encoding="utf-8")
        pids = set()
        for line in out.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                if int(parts[1]) == self.p.pid and "__lua-vm-worker" in parts[2]:
                    pids.add(int(parts[0]))
        return pids

    def assert_reaped(self, pids):
        if not pids:
            return
        deadline = time.monotonic() + 10
        while any(self._pid_alive(pid) for pid in pids):
            if time.monotonic() >= deadline:
                raise AssertionError(f"worker pids survived: {pids}")
            self.call("cells.get")

    def close(self):
        try:
            if self.p.poll() is None:
                self.call("shutdown", timeout=10)
                self.p.stdin.close()
                assert self.p.wait(timeout=10) == 0
        finally:
            if self.p.poll() is None:
                self.p.kill()
                self.p.wait()


def build_fixture(base):
    package = base / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    shutil.copytree(ROOT / "plugins/codemode", package / "plugins/codemode")
    probe = package / "plugins/probe"
    probe.mkdir()
    (probe / "init.lua").write_text(
        r"""return {
  name = "probe",
  inject = { "tools", "commands", "policy" }, -- session is optional: read with ctx:get("session")
  apply = function(ctx)
    local last_cell_id
    ctx.policy:rewriter("tool/rewrite", function(call)
      if call.name == "codemode_wait" and call.arguments.cell_id == "LAST_CELL_ID" then
        assert(last_cell_id, "no running cell id captured")
        call.arguments.cell_id = last_cell_id
      end
      return call.arguments
    end)
    local chain_seen = {}
    ctx:on("tool/result", function(data, ev)
      local result, call, budget = data.result, data.call, data.operation
      if call.name == "codemode" and type(result.details) == "table" and result.details.cell_id then
        last_cell_id = result.details.cell_id
      end
      chain_seen[call.id or call] = { call = call, budget = budget }
      return ev.next(data)
    end)
    -- downstream of the listener above (reached through ev.next()): core passes
    -- { result = display, call = call, operation = retention } and ev.next() must keep all three
    ctx:on("tool/result", function(data, ev)
      local result, call, budget = data.result, data.call, data.operation
      local report = mare.env("CODEMODE_CHAIN_REPORT")
      local seen = call and chain_seen[call.id or call]
      if report then
        assert(mare.fs.write(report, mare.json.encode_strict({
          tool = call and call.name or "",
          result = type(result) == "table",
          same_call = seen ~= nil and call == seen.call,
          same_budget = seen ~= nil and budget == seen.budget,
          budget = type(budget) == "table" and type(budget.max_bytes) == "number",
        }) .. "\n", { append = true }))
      end
      if call then chain_seen[call.id or call] = nil end
      return ev.next()
    end)
    ctx:on("turn/completed", function()
      local path = mare.env("CODEMODE_SESSION_REPORT")
      if path and ctx:get("session") then
        mare.fs.write(path, mare.json.encode_strict(ctx:get("session"):info()))
      end
    end)
  end,
}
""",
        encoding="utf-8",
    )

    config = base / "home/config"
    config.mkdir(parents=True)
    work_a = base / "work_a"
    work_b = base / "work_b"
    work_a.mkdir()
    work_b.mkdir()
    (work_a / "marker.txt").write_text("from_work_a\n", encoding="utf-8")
    (work_b / "marker.txt").write_text("from_work_b\n", encoding="utf-8")
    (config / "init.lua").write_text(
        f"""mare.setup {{ model = "faux/echo" }}
mare.plugins.add {{ {{ "test/codemode", url = "{package.as_uri()}" }} }}
mare.plugin("cells", {{ execution_mode = "persistent-in-memory" }})
""",
        encoding="utf-8",
    )
    for args in (
        ["git", "init", "-q", "-b", "main"],
        ["git", "add", "."],
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
    ):
        r = subprocess.run(args, check=False, cwd=package, capture_output=True, text=True, timeout=30, encoding="utf-8")
        assert r.returncode == 0, (args, r.stdout, r.stderr)
    env = os.environ.copy()
    env["MARE_HOME"] = str(base / "home")
    env["CODEMODE_CHAIN_REPORT"] = str(base / "tool-result-chain.jsonl")
    r = subprocess.run([BIN, "plugin", "sync"], check=False, cwd=work_a, env=env, capture_output=True, text=True, timeout=60, encoding="utf-8")
    assert r.returncode == 0, (r.stdout, r.stderr)
    return work_a, work_b, env


def register_host_tools(client):
    for name, desc in (("host_hold", "hold until released"), ("host_fast", "return ok")):
        client.call(
            "tools.register",
            {
                "name": name,
                "description": desc,
                "parameters": {"type": "object"},
                "side_effect": "read",
                "callbacks": ["execute"],
            },
        )


def run_command_tests(base, work_a, env):
    cmd_script = base / "cmd-script.json"
    cmd_script.write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'tools.host_hold({tag="cmd_stop"})', "yield_time_ms": 0}}]},
                {"text": "cell started"},
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'g_val=123; store("k",{n=42}); return g_val'}}]},
                {"text": "seeded"},
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'return {g=g_val, k=load("k")}'}}]},
                {"text": "checked reset"},
            ]
        ),
        encoding="utf-8",
    )
    env = env.copy()
    env["MARE_FAUX_SCRIPT"] = str(cmd_script)
    client = RpcClient([BIN, "--rpc", "--yolo"], env, work_a)
    try:
        client.call("initialize", {"protocol_version": "3.0", "capabilities": {"tools": True, "callbacks": True, "ui": True}})
        client.call("events.subscribe", {"scope": "all", "include": ["item/started", "item/completed", "turn/completed", "status/changed"]})
        register_host_tools(client)

        # 1. /codemode status and /codemode bogus
        n0 = len(client.notifies)
        client.call("commands.run", {"line": "/codemode status"})
        client.pump_until(lambda: len(client.notifies) > n0)
        assert client.notifies[-1]["level"] == "info"
        assert "Scripts running: 0; active cells: 0; stored keys: 0; mode: retained." in client.notifies[-1]["text"], client.notifies[-1]

        n0 = len(client.notifies)
        client.call("commands.run", {"line": "/codemode bogus"})
        client.pump_until(lambda: len(client.notifies) > n0)
        assert (client.notifies[-1].get("text"), client.notifies[-1].get("level")) == ("Usage: /codemode status|reset|stop [cell_id]", "warning"), client.notifies[-1]

        # 2. /codemode stop <active_cell_id> -> cancels host callback & reaps PID; missing after stop
        client.prompt_wait("start bg cell")
        client.pump_until(lambda: len(client.held_tools) == 1)
        cm_end = [e["data"]["item"]["message"] for e in client.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode"][-1]
        assert cm_end["details"]["status"] == "running", cm_end
        cell_id = cm_end["details"]["cell_id"]
        held_id = client.held_tools.pop(0)["id"]
        pids = client.worker_pids()

        n0 = len(client.notifies)
        c0 = len(client.cancels)
        client.call("commands.run", {"line": f"/codemode stop {cell_id}"})
        client.pump_until(lambda: len(client.notifies) > n0 and len(client.cancels) > c0)
        assert any(c.get("id") == held_id for c in client.cancels), client.cancels
        assert (client.notifies[-1].get("text"), client.notifies[-1].get("level")) == (f"Cell {cell_id} terminated.", "info"), client.notifies[-1]
        client.assert_reaped(pids)

        n0 = len(client.notifies)
        client.call("commands.run", {"line": f"/codemode stop {cell_id}"})
        client.pump_until(lambda: len(client.notifies) > n0)
        assert (client.notifies[-1].get("text"), client.notifies[-1].get("level")) == (f"Cell {cell_id} not found or already completed.", "warning"), client.notifies[-1]

        # 4. /codemode reset reaps retained codemode worker & clears store/globals
        client.prompt_wait("seed codemode state")
        pids = client.worker_pids()
        n0 = len(client.notifies)
        client.call("commands.run", {"line": "/codemode status"})
        client.pump_until(lambda: len(client.notifies) > n0)
        assert "stored keys: 1" in client.notifies[-1]["text"], client.notifies[-1]

        n0 = len(client.notifies)
        client.call("commands.run", {"line": "/codemode reset"})
        client.pump_until(lambda: len(client.notifies) > n0)
        assert (client.notifies[-1].get("text"), client.notifies[-1].get("level")) == ("Program memory reset; completed tool effects remain.", "info"), client.notifies[-1]
        if pids:
            assert not any(client._pid_alive(pid) for pid in pids)
        client.events.clear()
        client.prompt_wait("verify reset")
        reset_end = [e["data"]["item"]["message"] for e in client.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode"][-1]
        res_obj = reset_end["details"]["result"]
        assert res_obj is None or (res_obj.get("g") is None and res_obj.get("k") is None), reset_end
    finally:
        client.close()


def run_policy_and_cwd_and_owner_tests(base, work_a, work_b, env):
    client = RpcClient([BIN, "--rpc", "--yolo"], env, work_a)
    try:
        client.call("initialize", {"protocol_version": "3.0", "capabilities": {"tools": True, "callbacks": True, "ui": True}})
        register_host_tools(client)

        # Retained cross-cell same-owner busy refusal vs distinct state_owner concurrent execution
        client.request("cells.start", {"cell_id": "owner-hold", "code": 'owner_g=7; tools.host_hold({tag="owner"})', "capabilities": ["host_hold"], "yield_time_ms": 0})
        client.pump_until(lambda: len(client.held_tools) == 1)
        try:
            busy = client.call("cells.start", {"cell_id": "same-owner", "code": "return 1"})
            assert busy["status"] == "failed" and "already has an active execution" in busy["error"], busy
        except RuntimeError as exc:
            assert "already has an active execution" in str(exc), exc
        other = client.call("cells.start", {"cell_id": "other-owner", "code": "owner_g=99; return owner_g", "state_owner": "peer-b"})
        assert other["status"] == "completed" and other["result"] == 99, other
        client.reply_tool(client.held_tools.pop(0), {"content": "resumed"})
        done = client.call("cells.wait", {"cell_id": "owner-hold", "yield_time_ms": 5000})
        assert done["status"] == "completed", done

        # Policy change (/permission read-only) invalidates retained VM, sets state_lost, and blocks write
        client.call("cells.start", {"cell_id": "pre-policy", "code": 'pol_g=55; return pol_g'})
        before_pol_pids = client.worker_pids()
        n0 = len(client.notifies)
        client.call("commands.run", {"line": "/permission read-only"})
        assert len(client.notifies) == n0, client.notifies
        client.assert_reaped(before_pol_pids)
        after_pol = client.call(
            "cells.start",
            {"cell_id": "post-policy", "code": 'local ok,e=pcall(tools.write,{path="blocked.txt",content="x"}); return {g=pol_g, write_ok=ok, err=tostring(e)}', "capabilities": ["write"]},
        )
        assert "environment was lost" in "".join(b.get("text", "") for b in after_pol.get("content", [])), after_pol
        assert after_pol["result"].get("g") is None and after_pol["result"].get("write_ok") is False, after_pol
        assert not (work_a / "blocked.txt").exists()

        # Creating a session in another cwd and closing the old one reaps old workers,
        # clears store/globals, and resolves relative paths against the new cwd.
        sid_a = client.session_id
        assert sid_a, "expected active session_id before cwd switch"
        client.call("cells.start", {"cell_id": "pre-cwd", "code": 'cwd_g=88; store("cwd_k",{v=1}); return tools.read({path="marker.txt"}).content', "capabilities": ["read"]})
        before_cwd_pids = client.worker_pids()
        sid_b = client.call("session.create", {"cwd": str(work_b)})["session_id"]
        assert sid_b != sid_a, (sid_a, sid_b)
        client.call("session.close", {"session_id": sid_a})
        client.assert_reaped(before_cwd_pids)
        after_cwd = client.call(
            "cells.start",
            {"cell_id": "post-cwd-b", "code": 'return {g=cwd_g, k=load("cwd_k"), marker=tools.read({path="marker.txt"}).content}', "capabilities": ["read"]},
        )
        assert after_cwd["result"].get("g") is None and after_cwd["result"].get("k") is None, after_cwd
        assert "from_work_b" in json.dumps(after_cwd["result"]["marker"]), after_cwd

        client.call("cells.start", {"cell_id": "pre-cwd-b", "code": 'cwd_g2=99; return cwd_g2'})
        before_b_pids = client.worker_pids()
        sid_a2 = client.call("session.create", {"cwd": str(work_a)})["session_id"]
        assert sid_a2 != sid_b, (sid_b, sid_a2)
        client.call("session.close", {"session_id": sid_b})
        client.assert_reaped(before_b_pids)
        after_a = client.call("cells.start", {"cell_id": "post-cwd-a", "code": 'return {g=cwd_g2, marker=tools.read({path="marker.txt"}).content}', "capabilities": ["read"]})
        assert after_a["result"].get("g") is None and "from_work_a" in json.dumps(after_a["result"]["marker"]), after_a
    finally:
        client.close()


def run_resume_tests(base, work_a, env):
    script = base / "resume-script.json"
    env = env.copy()
    env["MARE_FAUX_SCRIPT"] = str(script)
    script.write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'res_g=77; store("res_k",{n=7}); return tools.write({path="persisted.txt",content="saved"})'}}]},
                {"text": "turn 1 saved"},
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'return {g=res_g, k=load("res_k"), file=tools.read({path="persisted.txt"}).content}'}}]},
                {"text": "turn 2 resumed"},
            ]
        ),
        encoding="utf-8",
    )
    # In-process session.create + session.load + background cell reap on switch
    client = RpcClient([BIN, "--rpc", "--yolo"], env, work_a)
    try:
        client.call("initialize", {"protocol_version": "3.0", "capabilities": {"tools": True, "callbacks": True}})
        client.call("events.subscribe", {"scope": "all", "include": ["turn/completed", "item/completed"]})
        register_host_tools(client)
        s1_info = client.call("session.create")
        s1_id = s1_info["session_id"]
        client.prompt_wait("save session 1")
        assert (work_a / "persisted.txt").read_text(encoding="utf-8") == "saved"

        # Start an active background cell before switching sessions to ensure it gets cancelled/reaped
        client.request("cells.start", {"cell_id": "bg-switch", "code": 'tools.host_hold({tag="switch"})', "capabilities": ["host_hold"], "yield_time_ms": 0})
        client.pump_until(lambda: len(client.held_tools) == 1)
        bg_pids = client.worker_pids()
        c0 = len(client.cancels)
        client.call("session.create")
        client.call("session.close", {"session_id": s1_id})
        client.pump_until(lambda: len(client.cancels) > c0)
        client.assert_reaped(bg_pids)
        client.held_tools.clear()

        # session.load boots a fresh Host whose provider-faux starts at turn 0.
        script.write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "codemode", "arguments": {"input": 'return {g=res_g, k=load("res_k"), file=tools.read({path="persisted.txt"}).content}'}}]},
                    {"text": "turn 2 resumed"},
                ]
            ),
            encoding="utf-8",
        )
        resumed = client.call("session.load", {"session_id": s1_id})
        assert resumed["session_id"] == s1_id, resumed
        client.events.clear()
        client.prompt_wait("check resumed codemode state")
        cm_resumed = [e["data"]["item"]["message"] for e in client.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode"][-1]
        res_obj = cm_resumed["details"]["result"]
        assert res_obj.get("g") is None and res_obj.get("k") is None and "saved" in json.dumps(res_obj["file"]), cm_resumed
    finally:
        client.close()

    # Fresh-process --resume verifies conversation history + file effects persist while codemode globals/store reset
    script2 = base / "resume-fresh.json"
    script2.write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'return {g=res_g, k=load("res_k"), file=tools.read({path="persisted.txt"}).content}'}}]},
                {"text": "fresh process resumed"},
            ]
        ),
        encoding="utf-8",
    )
    env2 = env.copy()
    env2["MARE_FAUX_SCRIPT"] = str(script2)
    r = subprocess.run(
        [BIN, "--yolo", "--resume", s1_id, "-p", "--json", "check resumed session"],
        check=False,
        cwd=work_a,
        env=env2,
        capture_output=True,
        text=True,
        timeout=60,
        encoding="utf-8",
    )
    assert r.returncode == 0, (r.stdout, r.stderr)
    assert "fresh process resumed" in r.stdout and "saved" in r.stdout, r.stdout
    tool_ends = [json.loads(line)["data"]["item"]["message"] for line in r.stdout.splitlines() if json.loads(line).get("type") == "item/completed" and (json.loads(line)["data"].get("item") or {}).get("type") == "tool_call"]
    assert len(tool_ends) == 1
    res_obj = tool_ends[0]["details"]["result"]
    assert res_obj.get("g") is None and res_obj.get("k") is None and "saved" in json.dumps(res_obj["file"]), tool_ends


def run_midcall_abort_tests(base, work_a, env):
    script = base / "abort-script.json"
    script.write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'abort_g=1; store("abort_k",{n=1}); return tools.host_hold({tag="abort_cm"})'}}]},
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'return {g=abort_g, k=load("abort_k")}'}}]},
                {"text": "post abort complete"},
            ]
        ),
        encoding="utf-8",
    )
    env = env.copy()
    env["MARE_FAUX_SCRIPT"] = str(script)
    client = RpcClient([BIN, "--rpc", "--no-session", "--yolo"], env, work_a)
    try:
        client.call("initialize", {"protocol_version": "3.0", "capabilities": {"tools": True, "callbacks": True}})
        client.call("events.subscribe", {"scope": "all", "include": ["item/started", "item/completed", "turn/completed", "status/changed"]})
        register_host_tools(client)

        # 1. Mid-call abort during codemode host callback: $/cancel_request, PID reap, store rollback, state_lost
        client.call("agent.prompt", {"session_id": client.session_id, "input": "run host_hold inside codemode"})
        client.pump_until(lambda: len(client.held_tools) == 1)
        held_id = client.held_tools[0]["id"]
        pids = client.worker_pids()
        c0 = len(client.cancels)
        client.call("agent.cancel", {"session_id": client.session_id})
        client.pump_until(
            lambda: len(client.cancels) > c0
            and any(s.get("state") == "idle" for s in client.statuses)
            and any(e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" for e in client.events)
        )
        assert any(c.get("id") == held_id for c in client.cancels), client.cancels
        client.assert_reaped(pids)
        client.held_tools.clear()
        client.events.clear()
        client.statuses.clear()
        client.prompt_wait("verify rolled back state")
        cm_after_abort = [e["data"]["item"]["message"] for e in client.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode"][-1]
        assert "environment was lost" in json.dumps(cm_after_abort["content"]), cm_after_abort
        assert cm_after_abort["details"]["result"].get("g") is None and cm_after_abort["details"]["result"].get("k") is None, cm_after_abort
        client.events.clear()
        client.statuses.clear()

        # 2. Mid-call abort during codemode_wait cancels wait while background cell stays alive and finishes cleanly
        script2 = base / "abort-wait-script.json"
        script2.write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "codemode", "arguments": {"input": 'tools.host_hold({tag="survive_wait_abort"}); return "bg_survived"', "yield_time_ms": 0}}]},
                    {"tool_calls": [{"name": "codemode_wait", "arguments": {"cell_id": "LAST_CELL_ID", "yield_time_ms": 10000}}]},
                    {"tool_calls": [{"name": "codemode_wait", "arguments": {"cell_id": "LAST_CELL_ID", "yield_time_ms": 10000}}]},
                    {"text": "survived wait abort"},
                ]
            ),
            encoding="utf-8",
        )
        # Re-point faux script for a fresh RPC client reading script2
    finally:
        client.close()

    env2 = env.copy()
    env2["MARE_FAUX_SCRIPT"] = str(script2)
    client2 = RpcClient([BIN, "--rpc", "--no-session", "--yolo"], env2, work_a)
    try:
        client2.call("initialize", {"protocol_version": "3.0", "capabilities": {"tools": True, "callbacks": True}})
        client2.call("events.subscribe", {"scope": "all", "include": ["item/started", "item/completed", "turn/completed", "status/changed"]})
        register_host_tools(client2)
        client2.call("agent.prompt", {"session_id": client2.session_id, "input": "start bg cell then abort codemode_wait"})
        client2.pump_until(lambda: any(e.get("type") == "item/started" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode_wait" for e in client2.events))
        client2.pump_until(lambda: len(client2.held_tools) == 1)
        bg_cell_end = [e for e in client2.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode"]
        assert len(bg_cell_end) == 1 and bg_cell_end[0]["data"]["item"]["message"]["details"]["cell_id"]
        bg_pids = client2.worker_pids()

        client2.call("agent.cancel", {"session_id": client2.session_id})
        client2.pump_until(
            lambda: any(e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode_wait" for e in client2.events)
            and any(s.get("state") == "idle" for s in client2.statuses)
        )
        wait_end = [e["data"]["item"] for e in client2.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode_wait"][-1]
        assert wait_end["result_status"] == "error", wait_end
        details = wait_end["message"].get("details")
        assert isinstance(details, dict), wait_end
        assert details["status"] == "running" and (details.get("cancelled") is True or "Wait cancelled" in (details.get("error") or "")), wait_end
        if bg_pids:
            assert all(client2._pid_alive(pid) for pid in bg_pids), "background cell was killed when only wait aborted"

        # Now release the held tool callback and consume the still-running background cell via codemode_wait
        client2.events.clear()
        client2.reply_tool(client2.held_tools.pop(0), {"content": "resumed_after_wait_abort"})
        client2.prompt_wait("collect surviving background cell")
        final_end = [e["data"]["item"] for e in client2.events if e.get("type") == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call" and e["data"]["item"]["name"] == "codemode_wait"][-1]
        final_details = final_end["message"]["details"]
        assert final_end["result_status"] == "success" and final_details["status"] == "completed" and final_details["result"] == "bg_survived", final_end
    finally:
        client2.close()


def run_tui_pty_tests(base, work_a, env):
    import fcntl
    import re
    import select
    import termios

    def plain(raw):
        return re.sub(rb"\x1b\[[0-9;?<>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]", b"", raw).decode("utf-8", "replace")

    class PtyTui:
        def __init__(self, args, script, session_report):
            self.master, slave = os.openpty()
            # 50x100: the expanded transcript must fit the 14-line fixture plus header/source
            # (each print() is its own text block, rendered as its own paragraph)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, b"\x32\x00\x64\x00\x00\x00\x00\x00")
            self.answered = False
            self.out = b""

            def ctty():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            proc_env = env.copy()
            proc_env["TERM"] = "xterm-256color"
            proc_env["MARE_FAUX_SCRIPT"] = str(script)
            proc_env["CODEMODE_SESSION_REPORT"] = str(session_report)
            proc_env.pop("TMUX", None)
            self.p = subprocess.Popen(
                [BIN, "--yolo", "--model", "faux/echo", "--set", "plugins.onboarding.plugins=false", *args],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                cwd=str(work_a),
                env=proc_env,
                preexec_fn=ctty,  # noqa: PLW1509
                close_fds=True,
            )
            os.close(slave)

        def _read(self, timeout):
            r, _, _ = select.select([self.master], [], [], timeout)
            if not r:
                return b""
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return None if self.p.poll() is not None else b""
            if not chunk:
                return None if self.p.poll() is not None else b""
            self.out += chunk
            if not self.answered and b"\x1b[6n" in self.out:
                self.answered = True
                os.write(self.master, b"\x1b[3;1R\x1b[?62;22c")
            return chunk

        def pump(self, secs, until=None, until_exit=False):
            deadline = time.monotonic() + secs
            if until and until(self.out):
                return
            while time.monotonic() < deadline:
                chunk = self._read(0.05)
                if chunk is None:
                    break
                if not chunk and until_exit and self.p.poll() is not None:
                    break
                if until and until(self.out):
                    break

        def settle(self, quiet=0.35, ceiling=10):
            deadline = time.monotonic() + ceiling
            while time.monotonic() < deadline:
                chunk = self._read(quiet)
                if chunk is None or not chunk:
                    break

        def raw(self):
            try:
                return not (termios.tcgetattr(self.master)[3] & termios.ICANON)
            except termios.error:
                return False

        def ready(self):
            self.pump(30, until=lambda b: "\u2570".encode() in b)
            deadline = time.monotonic() + 30
            while not self.raw() and time.monotonic() < deadline:
                self.pump(0.05)
            self.settle(0.4)

        def submit(self, text, until):
            def refusals():
                return plain(self.out).count("startup is still in progress")

            seen = refusals()
            os.write(self.master, text + b"\r")
            deadline = time.monotonic() + 30
            while not until(self.out) and time.monotonic() < deadline:
                self.pump(0.5, until=lambda b, s=seen: until(b) or refusals() > s)
                if not until(self.out) and refusals() > seen:
                    seen = refusals()
                    self.settle(0.4)
                    os.write(self.master, b"\r")
            assert until(self.out), f"timed out waiting after submit {text!r}; tail:\n{plain(self.out)[-1500:]}"

        def send_key(self, keys, until):
            os.write(self.master, keys)
            self.pump(15, until=until)
            assert until(self.out), f"timed out waiting after key {keys!r}; tail:\n{plain(self.out)[-1500:]}"

        def quit(self):
            try:
                if self.p.poll() is None:
                    try:
                        os.write(self.master, b"\x04")
                    except OSError:
                        pass
                    self.pump(2, until_exit=True)
                deadline = time.monotonic() + 15
                while self.p.poll() is None and time.monotonic() < deadline:
                    try:
                        os.write(self.master, b"\x03")
                    except OSError:
                        pass
                    self.pump(0.4, until_exit=True)
                self.p.wait(timeout=15)
            finally:
                try:
                    os.close(self.master)
                except OSError:
                    pass

    session_report = base / "tui-session.json"
    pty_script = base / "tui-pty-script.json"
    compact_lines = 'for i=1,14 do print(string.format("PTY_COMPACT_%02d", i)) end; return "PTY_COMPACT_DONE"'
    pty_script.write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'error("PTY_FAIL_BOOM")'}}]},
                {"tool_calls": [{"name": "codemode", "arguments": {"input": compact_lines}}]},
                {"text": "TURN1_READY"},
                {"tool_calls": [{"name": "codemode", "arguments": {"input": 'for _=1,200 do sleep(50) end; return "SHOULD_CANCEL"', "yield_time_ms": 60000}}]},
                {"text": "AFTER_CANCEL"},
            ]
        ),
        encoding="utf-8",
    )
    tui = PtyTui([], pty_script, session_report)
    try:
        tui.ready()
        # 1. Failure card + compact clipped card in real TUI
        tui.submit(b"step 1 fail and compact", until=lambda b: "TURN1_READY" in plain(b))
        t1 = plain(tui.out)
        assert "Script failed" in t1 and "PTY_FAIL_BOOM" in t1, t1[-1500:]
        assert "more lines" in t1 and "PTY_COMPACT_14" in t1 and "PTY_COMPACT_DONE" in t1, t1[-1500:]
        assert "PTY_COMPACT_01" not in t1, t1[-1500:]

        # 2. User expand/collapse toggle (Ctrl+O opens expanded transcript; Ctrl+T exits back to prompt)
        m_exp = len(tui.out)
        tui.send_key(
            b"\x0f",
            until=lambda b: "PTY_COMPACT_01" in plain(b[m_exp:])
            and "PTY_COMPACT_14" in plain(b[m_exp:])
            and 'for i=1,14 do print(string.format("PTY_COMPACT_%02d", i))' in plain(b[m_exp:]),
        )
        m_cmp = len(tui.out)
        tui.send_key(b"\x14", until=lambda b: b"\x1b[?1049l" in b[m_cmp:])

        # 3. Live running card -> user Ctrl+C cancel
        m_run = len(tui.out)
        tui.submit(
            b"step 2 cancel",
            until=lambda b: "Running codemode" in plain(b[m_run:]) or "codemode · running" in plain(b[m_run:]),
        )
        tui.send_key(b"\x03", until=lambda b: "Interrupted" in plain(b[m_run:]) or "cancelled" in plain(b[m_run:]))
        tui.settle(0.3)
        assert "SHOULD_CANCEL" not in plain(tui.out[m_run:]), plain(tui.out[m_run:])
        assert session_report.exists(), "turn/completed did not write session report"
        session_path = json.loads(session_report.read_text(encoding="utf-8"))["path"]
    finally:
        tui.quit()

    # 4. Real TUI --resume restores prior session history in PTY
    resume_script = base / "tui-resume-script.json"
    resume_script.write_text(json.dumps([{"text": "resumed_unused"}]), encoding="utf-8")
    resumed = PtyTui(["--resume", session_path], resume_script, base / "tui-resume-session.json")
    try:
        resumed.ready()
        if "recorded in another directory" in plain(resumed.out):
            os.write(resumed.master, b"\x1b[B\r")
        resumed.pump(15, until=lambda b: "TURN1_READY" in plain(b))
        rt = plain(resumed.out)
        assert "PTY_FAIL_BOOM" in rt and "PTY_COMPACT_DONE" in rt and "TURN1_READY" in rt, rt[-1500:]
    finally:
        resumed.quit()


with tempfile.TemporaryDirectory(prefix="mare-codemode-matrix-") as tmp:
    base = pathlib.Path(tmp)
    work_a, work_b, env = build_fixture(base)
    run_command_tests(base, work_a, env)
    if os.name != "nt":
        run_tui_pty_tests(base, work_a, env)
    run_policy_and_cwd_and_owner_tests(base, work_a, work_b, env)
    run_resume_tests(base, work_a, env)
    run_midcall_abort_tests(base, work_a, env)
    # every tool/result the probe saw reached its downstream listener with the same call and budget
    chain = [json.loads(line) for line in (base / "tool-result-chain.jsonl").read_text(encoding="utf-8").splitlines()]
    assert chain and all(r["result"] and r["same_call"] and r["same_budget"] and r["budget"] for r in chain), chain
    assert any(r["tool"] == "codemode" for r in chain), chain

print("codemode matrix E2E: /codemode commands, real TUI/PTY lifecycle, policy/cwd/resume state loss, owner concurrency, and mid-call abort passed")
