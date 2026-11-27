#!/usr/bin/env python3
"""Public RPC canonical/display hook parity through a real isolated VM and host tool."""
import importlib.util
import os
import pathlib
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("rpc_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pty", "rpc_client.py"))
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


class Client(rpc.Client):
    hold = False
    held = None
    cancelled = None

    def dispatch(self, message):
        if message.get("method") == "$/cancel_request":
            self.cancelled = message["params"]["id"]
            return None
        if (
            self.hold
            and message.get("method") == "callback.call"
            and message["params"]["arguments"].get("event") == "tool/result"
            and message["params"]["arguments"]["args"][0]["call"]["name"] == "host_echo"
        ):
            self.held = message
            return None
        return super().dispatch(message)


with tempfile.TemporaryDirectory(prefix="mare-hooks-rpc-") as tmp:
    root = pathlib.Path(tmp)
    (root / "home/config").mkdir(parents=True)
    (root / "home/config/init.lua").write_text('mare.setup {model="faux/echo"}\n', encoding="utf-8")
    env = dict(os.environ, MARE_HOME=str(root / "home"))
    client = Client([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, root)
    counts = {"tool/result": 0}
    identities = []

    def hook(params):
        event = params["event"]
        assert params["mode"] == "waterfall", params
        payload = params["args"][0]
        result, call, operation = payload["result"], payload["call"], payload["operation"]
        if call["name"] != "host_echo":
            return None
        assert operation["execution_id"] == call["execution_id"]
        assert operation["snapshot"] == call["snapshot"]
        identities.append(operation["execution_id"])
        counts[event] += 1
        result["content"] = "RETAINED DISPLAY"
        return {"result": result}

    client.on_hook = hook
    client.on_tool = lambda message: {"content": "ORIGINAL RESPONSE"}
    try:
        init = client.call("initialize", {"protocol_version": "3.0", "capabilities": {"callbacks": True, "tools": True}})
        sid = init["session"]["session_id"]
        client.call("tools.register", {"name": "host_echo", "description": "echo", "parameters": {"type": "object"}, "side_effect": "read", "callbacks": ["execute"]})
        for event in counts:
            client.call("hooks.subscribe", {"session_id": sid, "event": event, "callbacks": ["handle"]})
        result = client.call("cells.start", {"session_id": sid, "cell_id": "replacement", "code": "return tools.host_echo({}).content", "capabilities": ["host_echo"]})
        assert result["result"] == "ORIGINAL RESPONSE", result
        assert counts == {event: 1 for event in counts}, counts
        assert len(set(identities)) == 1, identities

        client.hold = True
        pending = client.request("cells.start", {"session_id": sid, "cell_id": "cancel-post", "code": "return tools.host_echo({}).content", "capabilities": ["host_echo"]})
        while client.held is None:
            client.dispatch(client.read())
        cancel = client.request("cells.cancel", {"session_id": sid, "cell_id": "cancel-post"})
        replies = {}
        while pending not in replies or cancel not in replies or client.cancelled != client.held["id"]:
            response = client.dispatch(client.read())
            if response:
                replies[response["id"]] = response
        assert replies[pending]["result"].get("status") == "cancelled", replies[pending]
        assert counts == {event: 1 for event in counts}, counts
    finally:
        client.hold = False
        try:
            client.call("shutdown")
        finally:
            client.p.wait(timeout=10)
    print("hooks RPC: canonical replacement, display retention, execution identity, after-once and callback cancellation passed")
