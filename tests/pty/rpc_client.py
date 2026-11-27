#!/usr/bin/env python3
"""Minimal `mare --rpc` client (stdlib only) — doubles as the protocol's end-to-end test.

usage: rpc_client.py path/to/mare

Drives the scripted faux provider through: initialize -> host tool registration -> hook
interception (tool/before blocks `bash`) -> prompt (wait, turn_id-tagged events) -> history and
models -> prompt + abort -> state -> shutdown; disconnect during a policy hook; and
`approval.request` (allow_session runs the call, abort ends the turn).
"""

import http.server
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading

MALFORMED_RESULTS = [
    {}, None, {"content": None}, {"content": 42}, {"content": {}},
    {"content": [{}]}, {"content": [{"type": "text"}]},
    {"content": "ignored", "is_error": "not-a-boolean"},
]

SCRIPT = [
    {"tool_calls": [{"name": "lookup", "arguments": {"q": "answer", "n": None, "a": [], "o": {}}}]},
    {"tool_calls": [{"name": "malformed", "arguments": {}} for _ in MALFORMED_RESULTS]},
    {"tool_calls": [{"name": "bash", "arguments": {"command": "echo should-not-run"}}]},
    {"text": "done"},
    {"tool_calls": [{"name": "slow", "arguments": {}}]},
    {"text": "never reached"},
]


class Client:
    def __init__(self, argv, env, cwd):
        self.p = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env,
            cwd=cwd,
            text=True,
            bufsize=1,
            encoding="utf-8",
        )
        self.next_id = 0
        self.events = []
        self.tool_calls = []
        self.tool_names_by_reg = {}
        self._pending_tool_regs = {}
        self.hook_calls = []
        self.statuses = []
        self.on_tool = None
        self.approvals = []
        self.on_hook = None  # (params) -> hook value
        self.on_approval = None  # (params) -> decision  # (msg) -> result dict, or None to not answer

    def send(self, msg):
        msg["jsonrpc"] = "2.0"
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def request(self, method, params=None):
        self.next_id += 1
        params = params or {}
        if method == "tools.register" and isinstance(params, dict) and isinstance(params.get("name"), str):
            self._pending_tool_regs[self.next_id] = params["name"]
        self.send({"id": self.next_id, "method": method, "params": params})
        return self.next_id

    def notify(self, method, params=None):
        self.send({"method": method, "params": params or {}})

    def callback_update(self, request_id, partial):
        self.notify("callback.update", {"id": request_id, "partial": partial})

    def sid(self):
        return self.call("status.get", {})["session"]["session_id"]

    def prompt_wait(self, text, **extra):
        sid = self.sid()
        params = {"session_id": sid, "input": text, **extra}
        started = self.call("agent.prompt", params)
        return started, self.call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})

    def read(self):
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("mare closed stdout")
        msg = json.loads(line)  # stdout must carry protocol messages only
        assert msg.get("jsonrpc") == "2.0", msg
        return msg

    def dispatch(self, msg):
        """Handle server notifications / callbacks; returns the message if it's a response."""
        method = msg.get("method")
        if method is None:
            return msg
        if method == "event":
            ev = msg["params"]
            self.events.append(ev)
            if ev.get("type") == "status/changed":
                self.statuses.append(ev["data"])
        elif method == "callback.call" and msg["params"].get("callback") == "execute":
            args = msg["params"]["arguments"]
            reg_id = msg["params"].get("registration_id")
            ctx = args.get("ctx") or {}
            self.tool_calls.append({
                **args,
                "request_id": msg["id"],
                "registration_id": reg_id,
                "name": self.tool_names_by_reg.get(reg_id),
                "arguments": args.get("args"),
                "call_id": ctx.get("tool_call_id"),
            })
            result = self.on_tool(msg) if self.on_tool else {"content": "ok"}
            if result is not None:
                self.send({"id": msg["id"], "result": result})
        elif method == "callback.call":
            arguments = msg["params"]["arguments"]
            self.hook_calls.append(arguments)
            if self.on_hook:
                value = self.on_hook(arguments)
            else:
                call = arguments["args"][0]
                value = {"decision": "deny", "reason": "denied by host"} if call.get("name") == "bash" else None
            if arguments.get("mode") == "emit":
                self.send({"id": msg["id"], "result": None})
            elif arguments.get("mode") == "waterfall" and value is None:
                self.send({"id": msg["id"], "result": {"next": True}})
            else:
                self.send({"id": msg["id"], "result": {"value": value}})
        elif method == "approval.request":
            self.approvals.append(msg["params"])
            decision = self.on_approval(msg["params"]) if self.on_approval else "deny"
            self.send({"id": msg["id"], "result": decision if isinstance(decision, dict) else {"decision": decision}})
        elif method in ("ui.select", "ui.input", "ui.confirm"):
            self.send({"id": msg["id"], "result": {}})
        return None

    def wait(self, rid):
        while True:
            msg = self.dispatch(self.read())
            if msg is not None and msg.get("id") == rid:
                reg_name = self._pending_tool_regs.pop(rid, None)
                if "error" in msg:
                    raise RuntimeError(f"rpc error: {msg['error']}")
                res = msg["result"]
                if reg_name and isinstance(res, dict) and isinstance(res.get("registration_id"), str):
                    self.tool_names_by_reg[res["registration_id"]] = reg_name
                return res

    def call(self, method, params=None):
        return self.wait(self.request(method, params))

    def call_error(self, method, params=None):
        rid = self.request(method, params)
        while True:
            msg = self.dispatch(self.read())
            if msg is not None and msg.get("id") == rid:
                assert "error" in msg and "result" not in msg, msg
                return msg["error"]

    def wait_status(self, state):
        """Read until the latest status/changed has this state (notifications are async: the
        final state may arrive just after the response that ended the turn)."""
        while not (self.statuses and self.statuses[-1]["state"] == state):
            self.dispatch(self.read())

    def wait_event(self, kind):
        while True:
            for e in self.events:
                if e["type"] == kind:
                    self.events.remove(e)
                    return e
            self.dispatch(self.read())


def queued_image_prompt(mare, env, work, crash=False):
    """Hold the first HTTP request open so busy admission cannot race completion."""
    requests = queue.Queue()
    release = threading.Event()

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.put((self.path, body))
            assert release.wait(15), "first provider request was never released"
            payload = (
                'event: response.output_text.delta\n'
                'data: {"type":"response.output_text.delta","item_id":"msg","delta":"done"}\n\n'
                'event: response.output_item.done\n'
                'data: {"type":"response.output_item.done","item":{"id":"msg","type":"message",'
                '"role":"assistant","content":[{"type":"output_text","text":"done"}]}}\n\n'
                'event: response.completed\n'
                'data: {"type":"response.completed","response":{"id":"test",'
                '"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                # The crash-recovery case deliberately kills the first client.
                pass

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    c = None
    try:
        rpc_env = dict(env, OPENAI_API_KEY="test-key")
        argv = [
            mare, "--rpc", "--yolo", "--model", "openai/gpt-6.1-terra",
            "--set", f"plugins.provider-openai.base_url=http://127.0.0.1:{server.server_port}",
            "--set", "plugins.provider-openai.transport=http",
        ]
        c = Client(argv + ([] if crash else ["--no-session"]), rpc_env, work)
        init = c.call("initialize", {"protocol_version": "3.0"})
        sid = init["session"]["session_id"]
        started = c.call("agent.prompt", {"session_id": sid, "input": "first turn"})
        assert started["status"] == "started", started
        _, first = requests.get(timeout=15)
        assert "first turn" in json.dumps(first), first
        image = {"type": "image", "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC", "mime": "image/png"}
        second_image = {"type": "image", "data": "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "mime": "image/gif"}
        queued = c.call("agent.prompt", {
            "session_id": sid,
            "input": [{"type": "text", "text": "queued image"}, image, second_image],
        })
        assert queued["status"] == "queued", queued
        if crash:
            # SIGKILL after durable queue admission, before the first request can finish.
            c.p.kill()
            c.p.wait(timeout=10)
            c.p.stdin.close()
            c.p.stdout.close()
            release.set()
            c = Client(argv + ["--continue"], rpc_env, work)
            c.call("initialize", {"protocol_version": "3.0"})
            assert isinstance(c.call("commands.run", {"line": "/continue"}), dict)
            _, retry = requests.get(timeout=15)
            assert "first turn" in json.dumps(retry), retry
        else:
            release.set()
        path, body = requests.get(timeout=15)
        assert path == "/responses", path
        def is_disclosure(item):
            content = item.get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, list) and content and isinstance(content[0], dict):
                text = content[0].get("text", "")
            else:
                text = ""
            return isinstance(text, str) and text.startswith("<system-reminder>")

        users = [item for item in body["input"] if item.get("role") == "user" and not is_disclosure(item)]
        assert len(users) == 2, body
        assert users[-1]["content"] == [
            {"type": "input_text", "text": "queued image"},
            {"type": "input_image", "image_url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC", "detail": "auto"},
            {"type": "input_image", "image_url": "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "detail": "auto"},
        ], body
        for attachment in (image, second_image):
            assert sum(json.dumps(item).count(attachment["data"]) for item in body["input"]) == 1, body
        c.wait_event("turn/completed")
        assert isinstance(c.call("shutdown"), dict)
        c.p.stdin.close()
        assert c.p.wait(timeout=20) == 0
        assert requests.empty(), "queued prompt caused duplicate provider requests"
        if crash:
            # A second restart must not resurrect the consumed inbox entry.
            c = Client(argv + ["--continue"], rpc_env, work)
            init2 = c.call("initialize", {"protocol_version": "3.0"})
            sid2 = init2["session"]["session_id"]
            completed = c.call("agent.prompt", {"session_id": sid2, "input": "fresh turn"})
            assert completed["status"] == "started", completed
            c.call("agent.wait", {"session_id": sid2, "turn_id": completed["turn_id"]})
            _, replayed = requests.get(timeout=15)
            users = [item for item in replayed["input"] if item.get("role") == "user" and not is_disclosure(item)]
            assert len(users) == 3, replayed
            for attachment in (image, second_image):
                assert sum(json.dumps(item).count(attachment["data"]) for item in replayed["input"]) == 1, replayed
            assert isinstance(c.call("shutdown"), dict)
            c.p.stdin.close()
            assert c.p.wait(timeout=20) == 0
            assert requests.empty(), "consumed queue entry replayed after a second restart"
    finally:
        release.set()
        if c is not None and c.p.poll() is None:
            c.p.kill()
            c.p.wait(timeout=10)
        server.shutdown()
        server.server_close()


def host_tool_terminate(mare, env, work):
    """A host tool result with terminate=true ends the run without another model request;
    the second scripted reply is never asked for."""
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "faux.json")
        with open(script, "w", encoding="utf-8") as f:
            json.dump([{"tool_calls": [{"name": "finish_tool", "arguments": {}}]}, {"text": "asked again"}], f)
        rpc_env = dict(env, MARE_HOME=os.path.join(tmp, "home"), MARE_FAUX_SCRIPT=script)
        c = Client([mare, "--rpc", "--yolo", "--model", "faux/echo"], rpc_env, work)
        try:
            c.call("initialize", {"protocol_version": "3.0", "capabilities": {"tools": True, "callbacks": True}, "callback_timeout_ms": 10000})
            c.call("tools.register", {"name": "finish_tool", "description": "Ends the run",
                                      "parameters": {"type": "object", "properties": {}}, "side_effect": "read", "callbacks": ["execute"]})
            c.on_tool = lambda m: {"content": "final answer", "terminate": True}
            c.prompt_wait("go")
            c.wait_status("idle")
            starts = [e for e in c.events if e["type"] == "step/started"]
            assert len(starts) == 1, starts
            texts = [e for e in c.events if e["type"] == "item/completed"
                     and (e["data"].get("item") or {}).get("message", {}).get("role") == "assistant"
                     and "asked again" in json.dumps(e["data"]["item"]["message"])]
            assert texts == [], texts
        finally:
            c.p.kill()


def empty_and_image_only_tool_results(mare, env, work):
    """Empty {"content": []} and image-only host tool results emit JSON arrays in RPC events."""
    png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "faux.json")
        with open(script, "w", encoding="utf-8") as f:
            json.dump(
                [
                    {
                        "tool_calls": [
                            {"name": "empty_tool", "arguments": {}},
                            {"name": "image_only_tool", "arguments": {}},
                        ]
                    },
                    {"text": "done"},
                ],
                f,
            )
        rpc_env = dict(env, MARE_HOME=os.path.join(tmp, "home"), MARE_FAUX_SCRIPT=script)
        c = Client([mare, "--rpc", "--yolo", "--model", "faux/echo"], rpc_env, work)
        try:
            c.call(
                "initialize",
                {
                    "protocol_version": "3.0",
                    "client": {"name": "rpc_client.py"},
                    "capabilities": {"tools": True, "callbacks": True},
                    "callback_timeout_ms": 10000,
                },
            )
            c.call(
                "tools.register",
                {
                    "name": "empty_tool",
                    "description": "Returns an empty content array",
                    "parameters": {"type": "object", "properties": {}},
                    "side_effect": "read",
                    "callbacks": ["execute"],
                },
            )
            c.call(
                "tools.register",
                {
                    "name": "image_only_tool",
                    "description": "Returns an image-only content array",
                    "parameters": {"type": "object", "properties": {}},
                    "side_effect": "read",
                    "callbacks": ["execute"],
                },
            )

            def on_tool(m):
                tool_name = c.tool_names_by_reg.get(m["params"].get("registration_id"))
                if tool_name == "empty_tool":
                    return {"content": []}
                if tool_name == "image_only_tool":
                    return {"content": [{"type": "image", "data": png_b64, "mime": "image/png"}]}
                return {"content": "unexpected"}

            c.on_tool = on_tool
            _, r = c.prompt_wait("go")
            c.wait_status("idle")
            assert r.get("text") == "done", r

            expected_image_content = [{"type": "image", "data": png_b64, "mime": "image/png"}]

            def expected_content(name):
                return expected_image_content if name == "image_only_tool" else []

            tool_result_events = [
                e for e in c.events
                if e["type"] == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call"
            ]
            assert [e["data"]["item"]["name"] for e in tool_result_events] == [
                "empty_tool",
                "image_only_tool",
            ], tool_result_events
            for ev in tool_result_events:
                item = ev["data"]["item"]
                assert item["result_status"] == "success", ev
                content = item["message"]["content"]
                assert isinstance(content, list) and content == expected_content(item["name"]), ev

            empty_end = next(
                e for e in c.events
                if e["type"] == "item/completed"
                and (e["data"].get("item") or {}).get("type") == "tool_call"
                and e["data"]["item"]["name"] == "empty_tool"
            )
            assert empty_end["data"]["item"]["result_status"] == "success", empty_end
            assert isinstance(empty_end["data"]["item"]["message"]["content"], list), empty_end
            assert empty_end["data"]["item"]["message"]["content"] == [], empty_end

            image_user_msgs = [
                e for e in c.events
                if e["type"] == "item/completed"
                and (e["data"].get("item") or {}).get("message", {}).get("role") == "user"
                and any(
                    b.get("type") == "image" and b.get("data") == png_b64
                    for b in e["data"]["item"]["message"].get("content", [])
                )
            ]
            assert len(image_user_msgs) == 0, c.events

            for msg_source in (r["messages"], c.call("agent.list_messages", {"session_id": c.sid()})["data"]):
                tr = [m for m in msg_source if m.get("role") == "tool_result"]
                assert [m["tool_name"] for m in tr] == ["empty_tool", "image_only_tool"], tr
                for m in tr:
                    assert isinstance(m["content"], list) and m["content"] == expected_content(m["tool_name"]), m
        finally:
            c.call("shutdown", {})
            c.p.wait(timeout=10)


def options_redaction_and_describe(mare, work):
    with tempfile.TemporaryDirectory() as home:
        cfg_dir = os.path.join(home, "config")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "init.lua"), "w", encoding="utf-8") as f:
            f.write(
                """
mare.setup({ border = "double", editor = "sk-PY_RAW_TOKEN_1234567890abcdef" })
mare.provider("example", {
  api_key = "PY_API_KEY_SENTINEL",
  headers = { ["X-Secret"] = "PY_HDR_SENTINEL" },
  query = { token = "PY_QUERY_SENTINEL" },
  query_params = { sig = "PY_QP_SENTINEL" },
  base_url = "https://example.invalid/?secret=PY_URL_SENTINEL",
  retries = 4,
})
mare.plugin("probe", {
  private_value = "PY_PLUGIN_SECRET",
  public_value = "py-ok",
  nested = { headers = { Authorization = "Bearer PY_NESTED_HDR" }, query = { auth = "PY_NESTED_Q" } },
})
mare.config_sensitive("plugins.probe.private_value")
"""
            )
        env = dict(os.environ, MARE_HOME=home)
        c = Client([mare, "--rpc", "--yolo", "--model", "faux/echo", "--no-session"], env, work)
        try:
            init = c.call("initialize", {"protocol_version": "3.0"})
            sid = init["session"]["session_id"]
            assert "config.describe" in init["capabilities"]["methods"], init
            sentinels = (
                "PY_RAW_TOKEN_1234567890abcdef",
                "PY_API_KEY_SENTINEL",
                "PY_HDR_SENTINEL",
                "PY_QUERY_SENTINEL",
                "PY_QP_SENTINEL",
                "PY_URL_SENTINEL",
                "PY_PLUGIN_SECRET",
                "PY_NESTED_HDR",
                "PY_NESTED_Q",
            )
            for req in ({}, {"keys": []}, {"keys": ["providers"]}):
                res = c.call("options.get", {"session_id": sid, **req})
                dumped = json.dumps(res)
                for s in sentinels:
                    assert s not in dumped, f"{s} leaked in {req}: {dumped}"
                assert res["providers"]["example"]["api_key"] == "[REDACTED]", res
                assert res["providers"]["example"]["headers"] == "[REDACTED]", res
                assert res["providers"]["example"]["query"] == "[REDACTED]", res
                assert res["providers"]["example"]["query_params"] == "[REDACTED]", res
                assert res["providers"]["example"]["retries"] == 4, res
                if "plugins" in res:
                    assert res["plugins"]["probe"]["private_value"] == "[REDACTED]", res
                    assert res["plugins"]["probe"]["public_value"] == "py-ok", res
                    assert res["plugins"]["probe"]["nested"]["headers"] == "[REDACTED]", res
                    assert res["plugins"]["probe"]["nested"]["query"] == "[REDACTED]", res
            dotted = c.call("options.get", {"session_id": sid, "keys": ["plugins.probe.private_value", "plugins.probe.public_value"]})
            assert dotted["plugins.probe.private_value"] == "[REDACTED]", dotted
            assert dotted["plugins.probe.public_value"] == "py-ok", dotted
            desc = c.call("options.get", {"session_id": sid, "keys": ["border", "providers", "plugins.probe.private_value"], "describe": True})
            dumped_desc = json.dumps(desc)
            for s in sentinels:
                assert s not in dumped_desc, f"{s} leaked in describe: {dumped_desc}"
            assert desc["border"]["effective"] == "double", desc
            assert desc["border"]["default"] == "rounded", desc
            assert desc["border"]["source"]["layer"] == "user", desc
            assert desc["border"]["redacted"] is False, desc
            assert desc["providers"]["redacted"] is True, desc
            assert desc["plugins.probe.private_value"]["effective"] == "[REDACTED]", desc
            assert desc["plugins.probe.private_value"]["sensitive"] is True, desc
            assert desc["plugins.probe.private_value"]["redacted"] is True, desc
            cfg = c.call("config.describe", {"keys": ["border", "providers"]})
            assert cfg["options"]["border"]["effective"] == "double", cfg
            assert cfg["options"]["providers"]["redacted"] is True, cfg
            assert isinstance(c.call("shutdown"), dict)
            c.p.stdin.close()
            assert c.p.wait(timeout=20) == 0
        finally:
            if c.p.poll() is None:
                c.p.kill()
                c.p.wait(timeout=10)


def main():
    mare = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "target/debug/mare")
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "faux.json")
        with open(script, "w", encoding="utf-8") as f:
            json.dump(SCRIPT, f)
        work = os.path.join(tmp, "work")
        os.makedirs(work)
        env = dict(
            os.environ, MARE_HOME=os.path.join(tmp, "home"), MARE_FAUX_SCRIPT=script
        )
        # Uninitialized connection: shutdown works, business methods fail (-32600).
        shut_only = Client([mare, "--rpc", "--yolo", "--model", "faux/echo", "--no-session"], env, work)
        assert isinstance(shut_only.call("shutdown"), dict)
        shut_only.p.stdin.close()
        assert shut_only.p.wait(timeout=20) == 0

        c = Client([mare, "--rpc", "--yolo", "--model", "faux/echo", "--no-session"], env, work)

        pre_init_calls = [
            ("agent.prompt", {"session_id": "s1", "input": "blocked"}),
            ("options.get", {"session_id": "s1"}),
            ("options.set", {"session_id": "s1", "values": {"effort": "low"}}),
            ("tools.register", {"name": "blocked", "description": "blocked", "parameters": {"type": "object"}, "callbacks": ["execute"]}),
            ("hooks.subscribe", {"session_id": "s1", "event": "status/changed", "callbacks": ["handle"]}),
            ("llm.list_models", {}),
            ("commands.run", {"line": "/help"}),
            ("agent.get", {"session_id": "s1"}),
            ("status.get", {}),
        ]
        for method, params in pre_init_calls:
            err = c.call_error(method, params)
            assert err["code"] == -32600, (method, err)

        for bad_version in ("1.7", "2", "2.invalid", "2.0.1", "", " 2.0"):
            err = c.call_error("initialize", {"protocol_version": bad_version})
            assert err["data"]["code"] == "unsupported_version", (bad_version, err)
            for method, params in pre_init_calls[:3]:
                after = c.call_error(method, params)
                assert after["code"] == -32600, (bad_version, method, after)

        init = c.call(
            "initialize",
            {
                "protocol_version": "3.0",
                "client": {"name": "rpc_client.py"},
                "capabilities": {"tools": True, "callbacks": True, "ui": True},
                "callback_timeout_ms": 10000,
            },
        )
        assert (
            init["protocol_version"].split(".")[0] == "3"
            and "agent.prompt" in init["capabilities"]["methods"]
        ), init

        sid = init["session"]["session_id"]

        for payload in (
            {"session_id": sid, "input": [{"type": "video", "url": "https://example.com/clip.mp4"}]},
        ):
            err = c.call_error("agent.prompt", payload)
            assert err["code"] == -32602 and (err.get("data") or {}).get("code") == "invalid_arguments", (payload, err)

        # Provider hooks carry credentials and cannot be forwarded to an RPC host.
        for event in ("provider/request", "provider/transport", "provider/event"):
            try:
                c.call("hooks.subscribe", {"session_id": sid, "event": event, "callbacks": ["handle"]})
            except RuntimeError as error:
                msg = str(error).lower()
                assert "private" in msg or "does not allow remote" in msg, error
            else:
                raise AssertionError(f"RPC accepted private hook {event}")

        # Unsupported or missing schemas fail at registration and leave the connection usable.
        for bad in (
            {"name": "bad", "description": "bad", "parameters": {"type": "object", "properties": {"x": {"format": "email"}}}, "callbacks": ["execute"]},
            {"name": "missing", "description": "missing"},
        ):
            try:
                c.call("tools.register", bad)
            except RuntimeError as error:
                assert bad["name"] in str(error) or "invalid" in str(error).lower(), error
            else:
                raise AssertionError(f"accepted invalid schema: {bad}")

        c.call(
            "tools.register",
            {
                "name": "lookup",
                "description": "Look something up on the host",
                "parameters": {
                    "type": "object",
                    "properties": {"q": {"type": "string"}, "n": {"const": None},
                                   "a": {"type": "array"}, "o": {"type": "object"}},
                    "required": ["q", "n", "a", "o"],
                },
                "side_effect": "read",
                "callbacks": ["execute"],
            },
        )
        c.call(
            "tools.register",
            {
                "name": "slow",
                "description": "Never answers",
                "parameters": {"type": "object", "properties": {}},
                "callbacks": ["execute"],
            },
        )
        c.call(
            "tools.register",
            {
                "name": "malformed",
                "description": "Returns a malformed result from the host",
                "parameters": {"type": "object", "properties": {}},
                "callbacks": ["execute"],
            },
        )
        c.call("hooks.subscribe", {"session_id": sid, "event": "tool/before", "callbacks": ["handle"]})

        # 1. prompt: a valid host tool, a malformed host response surfaced as a tool error,
        # then a hook-blocked bash call and the final answer.
        malformed_results = iter(MALFORMED_RESULTS)

        def tool_result(m):
            tool_name = c.tool_names_by_reg.get(m["params"].get("registration_id"))
            if tool_name == "lookup":
                req_id = m["id"]
                c.callback_update(req_id, {"output": "searching..."})
                c.callback_update("unknown-request-id", {"output": "should-be-dropped"})
                c.send({"id": req_id, "result": {"content": "42"}})
                c.callback_update(req_id, {"output": "late-after-result"})
                return None
            if tool_name == "malformed":
                reply = next(malformed_results)
                if reply is None:
                    c.send({"id": m["id"], "result": None})
                return reply
            return None

        c.on_tool = tool_result
        started, result = c.prompt_wait("go")
        assert result.get("text") == "done", result
        assert [t["name"] for t in c.tool_calls] == ["lookup"] + ["malformed"] * len(MALFORMED_RESULTS), c.tool_calls
        assert c.tool_calls[0]["arguments"] == {"q": "answer", "n": None, "a": [], "o": {}}
        assert {h["args"][0]["name"] for h in c.hook_calls} == {"lookup", "malformed", "bash"}, (
            c.hook_calls
        )
        dump = json.dumps(result.get("messages", []))
        assert "42" in dump and "invalid_result" in dump and "denied by host" in dump, dump
        invalid_results = [
            m for m in result.get("messages", [])
            if m.get("role") == "tool_result" and m.get("tool_name") == "malformed"
        ]
        assert len(invalid_results) == len(MALFORMED_RESULTS), invalid_results
        assert all(m.get("is_error") for m in invalid_results), invalid_results
        tool_results = [
            e["data"]["item"]
            for e in c.events
            if e["type"] == "item/completed" and (e["data"].get("item") or {}).get("type") == "tool_call"
        ]
        assert tool_results, "no completed tool_call item/completed events"
        for tr in tool_results:
            assert isinstance(tr["tool_call_id"], str) and tr["tool_call_id"], tr
            assert isinstance(tr["name"], str) and tr["name"], tr
            assert tr["message"]["role"] == "tool_result", tr
            assert isinstance(tr["message"]["content"], list), tr
            assert tr["message"]["tool_call_id"] == tr["tool_call_id"], tr
        tool_updates = [
            e for e in c.events if e["type"] == "item/delta" and e["data"].get("kind") == "tool_output"
        ]
        assert any(
            e["data"].get("partial", {}).get("output") == "searching..." for e in tool_updates
        ), tool_updates
        assert not any(
            e["data"].get("partial", {}).get("output") in ("should-be-dropped", "late-after-result")
            for e in tool_updates
        ), tool_updates
        # every event of the run carries the prompt's turn_id; seq strictly increases
        turn = started["turn_id"]
        run_events = [e for e in c.events if e.get("turn_id") == turn]
        assert any(e["type"] == "turn/started" for e in run_events), c.events[:3]
        eseq = [e["seq"] for e in c.events]
        assert eseq == sorted(eseq) and len(set(eseq)) == len(eseq), eseq
        # history and models
        sid = c.sid()
        msgs = c.call("agent.list_messages", {"session_id": sid})["data"]
        assert any(m.get("role") == "assistant" for m in msgs), msgs
        assert "data" in c.call("session.list_items", {"session_id": sid})
        models = c.call("llm.list_models")
        assert any(m.get("ref") == "faux/echo" for m in models["data"]), models
        # unified state: working while the turn ran, idle after, seq increasing
        c.wait_status("idle")
        states = [s["state"] for s in c.statuses]
        assert "working" in states and states[-1] == "idle", states
        seqs = [s["seq"] for s in c.statuses]
        assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs), seqs

        # 2. prompt without waiting; abort while the host tool is pending
        c.events.clear()
        r = c.call("agent.prompt", {"session_id": sid, "input": "again"})
        assert r["status"] == "started", r
        while not any(t["name"] == "slow" for t in c.tool_calls):
            c.dispatch(c.read())
        slow_req_id = next(t["request_id"] for t in c.tool_calls if t["name"] == "slow")
        c.callback_update(slow_req_id, {"output": "working..."})
        live_update = next(
            iter(
                [
                    e
                    for e in c.events
                    if e["type"] == "item/delta" and e["data"].get("kind") == "tool_output"
                ]
            ),
            None,
        )
        while live_update is None:
            c.dispatch(c.read())
            live_update = next(
                iter(
                    [
                        e
                        for e in c.events
                        if e["type"] == "item/delta" and e["data"].get("kind") == "tool_output"
                    ]
                ),
                None,
            )
        assert live_update["data"]["partial"]["output"] == "working...", live_update
        try:
            c.call("session.rewind", {"session_id": sid})
        except RuntimeError as error:
            assert "turn" in str(error).lower(), error
        else:
            raise AssertionError("RPC session.rewind succeeded while a turn was running")
        assert c.call("agent.cancel", {"session_id": sid})
        c.callback_update(slow_req_id, {"output": "late-after-cancel"})
        end = c.wait_event("turn/completed")
        assert "never reached" not in json.dumps(end), end
        assert not any(
            e["type"] == "item/delta"
            and e["data"].get("kind") == "tool_output"
            and e["data"].get("partial", {}).get("output") == "late-after-cancel"
            for e in c.events
        ), c.events

        state = c.call("agent.get", {"session_id": c.call("status.get")["session"]["session_id"]})
        assert isinstance(state, dict), state
        assert isinstance(c.call("shutdown"), dict)
        c.p.stdin.close()
        code = c.p.wait(timeout=20)
        assert code == 0, f"exit code {code}"

        # 3. disconnect while a policy hook (tool/before) is pending: the call is denied —
        #    the tool never runs — and mare exits instead of waiting for the gone host
        marker = os.path.join(work, "ran")
        with open(script, "w", encoding="utf-8") as f:
            json.dump(
                [
                    {"tool_calls": [{"name": "bash", "arguments": {"command": f"touch {marker}"}}]},
                    {"text": "after"},
                ],
                f,
            )
        c = Client([mare, "--rpc", "--yolo", "--model", "faux/echo", "--no-session"], env, work)
        disc_sid = c.call(
            "initialize",
            {"protocol_version": "3.0", "capabilities": {"callbacks": True}, "callback_timeout_ms": 60000},
        )["session"]["session_id"]
        c.call("hooks.subscribe", {"session_id": disc_sid, "event": "tool/before", "callbacks": ["handle"]})
        c.request("agent.prompt", {"session_id": disc_sid, "input": "go"})
        while True:
            m = c.read()
            if m.get("method") == "callback.call":
                break
        c.p.stdin.close()  # disconnect mid-callback, never answering
        code = c.p.wait(timeout=20)
        assert code == 0, f"exit code {code}"
        assert not os.path.exists(marker), "tool ran although its policy hook disconnected"

        # 4. approvals over RPC: tool/before asks, the host answers approval.request —
        #    allow_session runs the first call, abort refuses the second and ends the turn
        one, two = os.path.join(work, "one"), os.path.join(work, "two")
        subdir = os.path.join(work, "subdir")
        os.mkdir(subdir)
        with open(script, "w", encoding="utf-8") as f:
            json.dump(
                [
                    {"tool_calls": [{"name": "bash", "arguments": {"command": f"cd {subdir}"}}]},
                    {"tool_calls": [{"name": "bash", "arguments": {"command": f"touch {one}"}}]},
                    {"tool_calls": [{"name": "bash", "arguments": {"command": f"touch {two}"}}]},
                    {"text": "never reached"},
                ],
                f,
            )
        c = Client([mare, "--rpc", "--yolo", "--model", "faux/echo", "--no-session"], env, work)
        init = c.call(
            "initialize",
            {"protocol_version": "3.0", "capabilities": {"callbacks": True, "approvals": True}},
        )
        assert init["capabilities"]["callbacks"]["approvals"], init
        c.call("hooks.subscribe", {"session_id": init["session"]["session_id"], "event": "tool/before", "callbacks": ["handle"]})
        c.on_hook = lambda params: (
            None if params["args"][0]["arguments"]["command"].startswith("cd ")
            else {"decision": "ask", "reason": "needs approval"}
        )
        c.on_approval = lambda p: "allow_session" if p["command"].endswith("one") else "abort"
        _, r = c.prompt_wait("go")
        assert os.path.exists(one) and not os.path.exists(two), r
        assert r.get("status") in ("cancelled", "failed"), r
        first = c.approvals[0]
        assert first["kind"] == "tool" and first["tool"] == "bash" and first["cwd"] == subdir, first
        assert first["reason"] == "needs approval", first
        assert isinstance(c.call("shutdown"), dict)
        c.p.stdin.close()
        assert c.p.wait(timeout=20) == 0
        # Structured permission grants use the same callback, including a partial response.
        grant_dir = os.path.join(work, "grant")
        os.mkdir(grant_dir)
        with open(script, "w", encoding="utf-8") as f:
            json.dump([
                {"tool_calls": [{"name": "request_permissions", "arguments": {
                    "additional_permissions": {"write": [grant_dir], "network": True},
                    "justification": "write the report", "scope": "session"}}]},
                {"tool_calls": [{"name": "write", "arguments": {"path": os.path.join(grant_dir, "report"), "content": "ok"}}]},
                {"text": "done"},
            ], f)
        c = Client([mare, "--rpc", "--permission", "read-only", "--model", "faux/echo", "--no-session"], env, work)
        c.call("initialize", {"protocol_version": "3.0", "capabilities": {"approvals": True}})
        c.on_approval = lambda p: {"decision": "allow", "permissions": {"write": [grant_dir]}, "scope": "session"}
        c.prompt_wait("write report")
        assert len(c.approvals) == 1, c.approvals
        assert c.approvals[0]["requested_permissions"]["network"] is True, c.approvals
        assert c.approvals[0]["scope"] == "session", c.approvals
        assert open(os.path.join(grant_dir, "report"), encoding="utf-8").read() == "ok"
        assert isinstance(c.call("shutdown"), dict)
        c.p.stdin.close()
        assert c.p.wait(timeout=20) == 0
        queued_image_prompt(mare, env, work)
        with tempfile.TemporaryDirectory() as recovery_home:
            queued_image_prompt(mare, dict(env, MARE_HOME=recovery_home), work, crash=True)
        host_tool_terminate(mare, env, work)
        empty_and_image_only_tool_results(mare, env, work)

        options_redaction_and_describe(mare, work)
    print("rpc_client: ok")


if __name__ == "__main__":
    main()
