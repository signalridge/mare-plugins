#!/usr/bin/env python3
"""Real bidirectional RPC, local socket ownership, cancellation and sandbox policy."""

import contextlib
import http.server
import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


BIN = os.environ["MARE_BIN"]

ROOT = Path(__file__).resolve().parents[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/page")
            self.end_headers()
            return
        if self.path == "/ua":
            body = self.headers.get("User-Agent", "").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=UTF-8")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/slow":
            time.sleep(0.3)
        body = (
            "<h1>RPC page</h1>"
            + "<p>ordinary paragraph</p>" * 1000
            + "<script>hidden</script>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=UTF-8")
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)


class Rpc:
    def __init__(self, reader, writer):
        self.writer = writer
        self.messages = queue.Queue()
        self.saved = []
        self.serial = 0

        def pump():
            for line in reader:
                self.messages.put(json.loads(line))
            self.messages.put(None)

        threading.Thread(target=pump, daemon=True).start()

    def send(self, method, params):
        self.serial += 1
        self.write(
            {"jsonrpc": "2.0", "id": self.serial, "method": method, "params": params}
        )
        return self.serial

    def write(self, message):
        self.writer.write(json.dumps(message) + "\n")
        self.writer.flush()

    def take(self, predicate):
        for i, message in enumerate(self.saved):
            if predicate(message):
                return self.saved.pop(i)
        while True:
            message = self.messages.get(timeout=30)
            assert message is not None, "RPC disconnected unexpectedly"
            if predicate(message):
                return message
            self.saved.append(message)

    def reply(self, request_id):
        return self.take(lambda m: m.get("id") == request_id and "method" not in m)

    def result(self, method, params):
        message = self.reply(self.send(method, params))
        assert "error" not in message, message
        return message["result"]

    def callback(self):
        return self.take(lambda m: m.get("method") == "callback.call")

    def answer(self, callback, result):
        self.write({"jsonrpc": "2.0", "id": callback["id"], "result": result})


def web_providers(rpc, kind):
    return rpc.result("web.list_providers", {"kind": kind})


def web_selection(rpc, kind):
    res = web_providers(rpc, kind)
    selected = [p for p in res["data"] if p.get("selected")]
    assert len(selected) <= 1, res
    return selected[0] if selected else res


def assert_web_error(reply, code):
    err = reply.get("error") or {}
    assert err.get("data", {}).get("code") == code, reply


def main():
    with tempfile.TemporaryDirectory(prefix="web-rpc-") as temp:
        root = Path(temp)
        home = root / "home"
        config = home / "config"
        config.mkdir(parents=True)
        work = root / "work"
        work.mkdir()
        base_config = 'mare.setup {model="faux/echo", peer={allow={"web.fetch", "web.search", "web.list_providers", "web.register_fetch", "web.register_search", "registrations.release"}}}\n'
        # this section is about RPC-registered backends only: core's built-in web-fetch-http
        # (http-text) would make every auto selection ambiguous and never leave the provider list
        (config / "init.lua").write_text(
            base_config + 'mare.plugin("web-fetch-http", { enabled = false })\n',
            encoding="utf-8",
        )
        probe = config / "plugins/web-rpc-policy"
        probe.mkdir(parents=True)
        (probe / "init.lua").write_text(
            """return {name="web-rpc-policy",inject={"commands","permissions"},apply=function(ctx)
            ctx.commands:register("web-readonly",{run=function() return ctx.permissions:set("read-only") end})
            end}""",
            encoding="utf-8",
        )
        env = dict(os.environ, MARE_HOME=str(home))
        proc = subprocess.Popen(
            [BIN, "-C", str(work), "--yolo", "--peer", "--rpc"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            encoding="utf-8",
        )
        rpc = Rpc(proc.stdout, proc.stdin)
        try:
            rpc.result("initialize", {"protocol_version": "3.0", "callback_timeout_ms": 150})
            unsupported = rpc.reply(
                rpc.send(
                    "web.register_fetch",
                    {"provider_id": "missing-capability", "callbacks": ["fetch"]},
                )
            )
            assert (unsupported.get("error") or {}).get("data", {}).get("code") == "unsupported", unsupported
            rpc.result(
                "connection.set_capabilities",
                {"capabilities": {"callbacks": True, "ui": False, "approvals": False, "elicitation": False}},
            )
            owner = rpc.result("session.create", {})
            owner_id = owner["session_id"]
            started = rpc.result("agent.prompt", {"session_id": owner_id, "input": "save RPC owner"})
            rpc.result("agent.wait", {"session_id": owner_id, "turn_id": started["turn_id"]})
            assert any(home.rglob("*.jsonl")), (
                "prompt did not create a durable session journal"
            )
            remote_reg = rpc.result(
                "web.register_fetch", {"provider_id": "remote", "callbacks": ["fetch"]}
            )
            remote_reg_id = remote_reg["registration_id"]
            selection = web_selection(rpc, "fetch")
            assert selection.get("provider_id") == "remote", (selection, web_providers(rpc, "fetch"))
            call = rpc.send("web.fetch", {"url": "https://example.test/source"})
            callback = rpc.callback()
            assert (
                callback["params"]["arguments"]["request"]["url"]
                == "https://example.test/source"
            )
            rpc.answer(
                callback,
                {
                    "requested_url": "https://example.test/source",
                    "content": "remote result",
                    "url": "https://example.test/final",
                },
            )
            assert rpc.reply(call)["result"]["content"] == "remote result"

            # Both a forked writer and a resumed saved writer need fresh real
            # admission; registrations remain connection-owned across the switch.
            forked = rpc.result("session.fork", {"session_id": owner_id})
            assert forked["session_id"] != owner_id, forked
            for label in ["forked", "resumed"]:
                if label == "resumed":
                    restored = rpc.result("session.load", {"session_id": owner_id})
                    assert restored["session_id"] == owner_id and not restored.get(
                        "readonly", False
                    ), restored
                call = rpc.send("web.fetch", {"url": f"https://example.test/{label}"})
                callback = rpc.callback()
                rpc.answer(
                    callback,
                    {
                        "requested_url": f"https://example.test/{label}",
                        "content": label,
                    },
                )
                assert rpc.reply(call)["result"]["content"] == label

            # A shorter service deadline clears callback resources.
            call = rpc.send(
                "web.fetch", {"url": "https://example.test/deadline", "timeout_ms": 20}
            )
            callback = rpc.callback()
            timed = rpc.reply(call)
            assert_web_error(timed, "timed_out")
            assert "WEB_TIMEOUT" in timed["error"]["message"], timed
            rpc.take(
                lambda m: (
                    m.get("method") == "$/cancel_request"
                    and m["params"]["id"] == callback["id"]
                )
            )
            call = rpc.send("web.fetch", {"url": "https://example.test/host-timeout"})
            rpc.callback()
            host_timed = rpc.reply(call)
            assert_web_error(host_timed, "timed_out")
            assert "WEB_CALLBACK_TIMEOUT" in host_timed["error"]["message"], host_timed
            call = rpc.send("web.fetch", {"url": "https://example.test/invalid"})
            rpc.answer(rpc.callback(), {"content": 5})
            assert "error" in rpc.reply(call)
            call = rpc.send("web.fetch", {"url": "https://example.test/error"})
            callback = rpc.callback()
            rpc.write(
                {
                    "jsonrpc": "2.0",
                    "id": callback["id"],
                    "error": {"code": -32000, "message": "fixture refused"},
                }
            )
            err_reply = rpc.reply(call)["error"]
            assert (
                err_reply.get("data", {}).get("code") == "internal"
                or "WEB_CALLBACK_ERROR" in err_reply["message"]
            ), err_reply
            call = rpc.send("web.fetch", {"url": "https://example.test/reload"})
            callback = rpc.callback()
            rpc.result("commands.run", {"line": "/reload web"})
            removed = rpc.reply(call)
            assert_web_error(removed, "unavailable")
            rpc.take(
                lambda m: (
                    m.get("method") == "$/cancel_request"
                    and m["params"]["id"] == callback["id"]
                )
            )
            assert (
                rpc.result("registrations.release", {"registration_id": remote_reg_id})
                == {}
            )
            assert (
                rpc.result("registrations.release", {"registration_id": remote_reg_id})
                == {}
            )

            # Search callbacks go through the same provider selection and query collector.
            search_reg_id = rpc.result(
                "web.register_search", {"provider_id": "search", "callbacks": ["search"]}
            )["registration_id"]
            call = rpc.send("web.search", {"queries": ["one", "one"]})
            callback = rpc.callback()
            assert callback["params"]["arguments"]["request"]["queries"] == ["one"]
            rpc.answer(
                callback,
                {
                    "data": [{"url": "https://example.test/result"}],
                    "content": "source",
                },
            )
            assert len(rpc.reply(call)["result"]["data"]) == 1
            rpc.result("registrations.release", {"registration_id": search_reg_id})

            # A second real socket connection owns its registrations. Other connections
            # cannot dispose them; loss of the owner cancels an in-flight callback.
            if hasattr(socket, "AF_UNIX"):
                registry = None
                for _ in range(100):
                    for path in home.rglob(f"{proc.pid}.json"):
                        value = json.loads(path.read_text(encoding="utf-8"))
                        if "socket" in value:
                            registry = value
                            break
                    if registry:
                        break
                    time.sleep(0.02)
                assert registry, "peer socket registry was not published"
                sock = socket.socket(socket.AF_UNIX)
                sock.connect(registry["socket"])
                stream = sock.makefile("rw")
                peer = Rpc(stream, stream)
                peer.result("initialize", {"protocol_version": "3.0", "capabilities": {"callbacks": True}})
                owned_reg_id = peer.result(
                    "web.register_fetch",
                    {"session_id": owner_id, "provider_id": "owned", "callbacks": ["fetch"]},
                )["registration_id"]
                assert (
                    rpc.result("registrations.release", {"registration_id": owned_reg_id})
                    == {}
                )
                assert web_selection(rpc, "fetch")["provider_id"] == "owned"
                call = rpc.send("web.fetch", {"url": "https://example.test/disconnect"})
                peer.callback()
                sock.shutdown(socket.SHUT_RDWR)
                stream.close()
                sock.close()
                disconnected = rpc.reply(call)
                assert "error" in disconnected, disconnected
                for _ in range(100):
                    if not web_providers(rpc, "fetch")["data"]:
                        break
                    time.sleep(0.01)
                else:
                    raise AssertionError("owner disconnect did not revoke backend")

            # A remote callback cannot pretend to be confined by the local sandbox.
            restricted_reg_id = rpc.result(
                "web.register_fetch", {"provider_id": "restricted", "callbacks": ["fetch"]}
            )["registration_id"]
            rpc.result("commands.run", {"line": "/web-readonly"})
            denied = rpc.reply(
                rpc.send("web.fetch", {"url": "https://example.test/denied"})
            )
            # The unconfined remote backend must be refused under the read-only sandbox; core maps
            # WEB_UNCONFINED_DENIED to error.data.code == "unavailable"
            assert "error" in denied and "result" not in denied, denied
            assert_web_error(denied, "unavailable")
            rpc.result("registrations.release", {"registration_id": restricted_reg_id})
            bounded_reg_ids = [
                rpc.result(
                    "web.register_fetch",
                    {"provider_id": f"bounded-{index}", "callbacks": ["fetch"]},
                )["registration_id"]
                for index in range(64)
            ]
            overflow = rpc.reply(
                rpc.send(
                    "web.register_fetch", {"provider_id": "overflow", "callbacks": ["fetch"]}
                )
            )
            assert_web_error(overflow, "invalid_arguments")
            assert "registration limit" in overflow["error"]["message"], overflow
            for reg_id in bounded_reg_ids:
                rpc.result("registrations.release", {"registration_id": reg_id})
            rpc.result("shutdown", {})
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        assert proc.returncode == 0, proc.stderr.read()
        # The actual HTTP backend runs through the same direct RPC service and the frozen
        # session network policy, rather than a separate RPC networking implementation.
        (config / "init.lua").write_text(base_config, encoding="utf-8")  # the core HTTP backend is used from here on
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            proc = subprocess.Popen(
                [BIN, "-C", str(work), "--yolo", "--rpc"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                encoding="utf-8",
            )
            rpc = Rpc(proc.stdout, proc.stdin)
            try:
                rpc.result("initialize", {"protocol_version": "3.0"})
                rpc_owner = rpc.result("session.create", {})
                rpc_owner_id = rpc_owner["session_id"]
                started = rpc.result(
                    "agent.prompt", {"session_id": rpc_owner_id, "input": "save actual HTTP RPC owner"}
                )
                rpc.result("agent.wait", {"session_id": rpc_owner_id, "turn_id": started["turn_id"]})
                url = f"http://127.0.0.1:{server.server_port}"
                page = rpc.result("web.fetch", {"url": url + "/page"})
                assert page["content"].count("ordinary paragraph") == 1000
                assert "RPC page" in page["content"] and "hidden" not in page["content"]
                slow = rpc.reply(
                    rpc.send("web.fetch", {"url": url + "/slow", "timeout_ms": 20})
                )
                assert_web_error(slow, "timed_out")
                assert "WEB_TIMEOUT" in slow["error"]["message"], slow
                rpc.result("commands.run", {"line": "/web mode disabled"})
                assert web_selection(rpc, "search")["reason"] == "disabled"
                rpc.result("commands.run", {"line": "/web mode cached"})
                assert web_selection(rpc, "search")["reason"] == "unavailable"
                rpc.result("commands.run", {"line": "/web fetch missing-backend"})
                assert (
                    web_selection(rpc, "fetch")["reason"]
                    == "configured_missing"
                )
                rpc.result("commands.run", {"line": "/web fetch http-text"})
                assert (
                    web_selection(rpc, "fetch")["provider_id"]
                    == "http-text"
                )
                rpc.result("commands.run", {"line": "/web fetch auto"})
                assert (
                    web_selection(rpc, "fetch")["provider_id"]
                    == "http-text"
                )
                with (config / "init.lua").open("a") as settings:
                    settings.write(
                        '\nmare.plugin("web-fetch-http",{redirect="manual",user_agent="reloaded-agent/2"})\n'
                    )
                rpc.result("commands.run", {"line": "/reload"})
                for _ in range(100):
                    resumed = rpc.reply(
                        rpc.send("session.load", {"session_id": rpc_owner_id})
                    )
                    if "error" not in resumed:
                        break
                    time.sleep(0.02)
                else:
                    raise AssertionError(resumed)
                manual_redirect = rpc.reply(
                    rpc.send("web.fetch", {"url": url + "/redirect"})
                )
                assert "HTTP 302" in manual_redirect["error"]["message"], (
                    manual_redirect
                )
                ua = rpc.result("web.fetch", {"url": url + "/ua"})
                assert ua["content"] == "reloaded-agent/2", ua
                rpc.result("commands.run", {"line": "/web-readonly"})
                denied = rpc.reply(rpc.send("web.fetch", {"url": url + "/page"}))
                assert "sandbox" in denied["error"]["message"], denied
                rpc.result("shutdown", {})
            finally:
                proc.stdin.close()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            assert proc.returncode == 0, proc.stderr.read()
    print(
        "web RPC: direct/search, reverse callbacks, owner disconnect, deadlines, cancellation and policy passed"
    )


if __name__ == "__main__":
    main()
