#!/usr/bin/env python3
"""Drive the real RPC UI callbacks for goal menu/edit/cancel, against an installed package."""
import json
import subprocess
import sys
import time

process = subprocess.Popen(
    [sys.argv[1], "-C", sys.argv[2], "--rpc", "--yolo"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    encoding="utf-8",
)
inputs = []
selections = []
notices = []
settled_ids=[]
ident = 0


def send(value):
    process.stdin.write(json.dumps(value) + "\n")
    process.stdin.flush()


def request(method, params):
    global ident
    ident += 1
    wanted = ident
    send({"jsonrpc": "2.0", "id": wanted, "method": method, "params": params})
    while True:
        line = process.stdout.readline()
        assert line, process.stderr.read()
        value = json.loads(line)
        if value.get("id") == wanted:
            assert "error" not in value, value
            return value.get("result")
        if value.get("method") == "event" and value.get("params", {}).get("type") == "turn/completed":
            settled_ids.append(value["params"]["data"]["turn_id"])
        if value.get("method") == "ui.notify":
            notices.append(value["params"])
        elif value.get("method") == "ui.select":
            assert selections, value
            choice = selections.pop(0)
            if value["params"].get("title") == "Goal":
                assert "Status:" in "\n".join(value["params"].get("body", [])) or "No goal" in "\n".join(value["params"].get("body", []))
            send({"jsonrpc": "2.0", "id": value["id"], "result": {"index": choice}})
        elif value.get("method") == "ui.input":
            assert inputs, value
            answer, expected_initial = inputs.pop(0)
            assert (value["params"].get("default") or "") == expected_initial, value
            send({"jsonrpc": "2.0", "id": value["id"], "result": {"text": answer}})


def check_readonly(session_id):
    other=subprocess.Popen([sys.argv[1],"-C",sys.argv[2],"--rpc","--yolo"],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True, encoding="utf-8")
    counter=0
    def call(method,params,allow_error=False):
        nonlocal counter
        counter+=1
        wanted=counter
        other.stdin.write(json.dumps({"jsonrpc":"2.0","id":wanted,"method":method,"params":params})+"\n")
        other.stdin.flush()
        while True:
            line=other.stdout.readline()
            assert line,"readonly RPC closed"
            value=json.loads(line)
            if value.get("id")==wanted:
                if allow_error:return value
                assert "error" not in value,value
                return value.get("result")
            if value.get("method")=="ui.select":
                # Read-only view and keep-paused are option two; the explicit
                # replacement confirmation is option one, then must be refused.
                index=0 if value["params"].get("title")=="Replace goal?" else 1
                other.stdin.write(json.dumps({"jsonrpc":"2.0","id":value["id"],"result":{"index":index}})+"\n")
                other.stdin.flush()
            elif value.get("method")=="ui.input":
                other.stdin.write(json.dumps({"jsonrpc":"2.0","id":value["id"],"result":{"text":None}})+"\n")
                other.stdin.flush()
    try:
        call("initialize",{"protocol_version": "3.0", "capabilities":{"ui":True}})
        # The public lifecycle now permits a readonly RPC projection. It must
        # display the goal while keeping the writer's durable record unchanged.
        loaded=call("session.load",{"session_id":session_id})
        params={"kind":"goal/state","session_id":loaded["session_id"]}
        before=call("session.list_records",params)["data"]
        assert before and before[-1]["goal"]["status"]=="paused", before
        call("commands.run",{"line":"/goal status"})
        call("commands.run",{"line":"/goal pause"})
        assert call("session.list_records",params)["data"]==before
        call("shutdown",{})
        assert other.wait(timeout=10)==0
    finally:
        if other.poll() is None:other.kill()
        other.wait()


try:
    init = request("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
    request("events.subscribe", {"scope": "all", "include": ["agent/*", "turn/*", "status/*"]})
    owner = request("session.create", {"subscribe": True})
    sid = owner["session_id"]

    def state():
        entries = request("session.list_records", {"kind": "goal/state", "session_id": owner["session_id"]})["data"]
        return entries[-1] if entries else None

    edit_empty = request("commands.run", {"line": "/goal edit"})["result"]
    assert edit_empty["status"] == "rejected" and "no current goal" in edit_empty["reason"], edit_empty
    clear_empty = request("commands.run", {"line": "/goal clear"})["result"]
    assert clear_empty["status"] == "rejected" and "no current goal" in clear_empty["reason"], clear_empty

    request("commands.run", {"line": "/plan on"})
    selections.append(0)
    inputs.extend([("UI objective", ""), ("5000", "")])
    request("commands.run", {"line": "/goal"})
    assert request("agent.list_messages", {"session_id": sid})["data"] == [], "plan mode admitted a goal round"
    request("commands.run", {"line": "/plan off"})
    deadline = time.monotonic() + 10
    while state()["goal"]["status"] != "paused" or not settled_ids:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    request("agent.wait", {"session_id": sid, "turn_id": settled_ids[-1]})
    activity= request("agent.get",{"session_id": sid})["activity"]
    assert activity["extra"]["goal"]["status"]=="paused",activity
    assert activity["extra"]["goal"]["objective_preview"]=="UI objective"
    assert not activity.get("extra_errors"),activity
    before = state()
    inputs.append((None, "UI objective"))
    request("commands.run", {"line": "/goal edit"})
    assert state() == before, "cancelling input changed the durable goal"
    # Confirming the real initial buffer keeps the existing objective and budget.
    inputs.extend([("UI objective", "UI objective"), ("", "")])
    request("commands.run", {"line": "/goal edit"})
    assert state()["goal"]["objective"] == "UI objective"
    assert state()["goal"]["token_budget"] == 5000
    # Clearing an editable objective is invalid; it must not silently restore it.
    before = state()
    inputs.append(("", "UI objective"))
    request("commands.run", {"line": "/goal edit"})
    assert state() == before, "an empty edit replaced or silently restored the objective"
    inputs.extend([("UI revised objective", "UI objective"), ("6000", "")])
    request("commands.run", {"line": "/goal edit"})
    current = state()["goal"]
    assert current["objective"] == "UI revised objective" and current["token_budget"] == 6000
    assert current["status"] == "paused", "editing paused goal must retain its phase"
    selections.append(None)
    request("commands.run", {"line": "/goal"})
    assert any("Tokens used:" in str(item) for item in notices), notices
    # New sessions created by fork inherit conversation history, not goal state.
    source_id = owner["session_id"]
    owner = request("session.fork", {"session_id": source_id, "subscribe": True})
    sid = owner["session_id"]
    assert state() is None, "fork inherited a session-wide goal"
    request("session.close", {"session_id": source_id})
    selections.append(1)  # Keep the resumed goal paused in its explicit resume prompt.
    owner = request("session.load", {"session_id": source_id, "subscribe": True})
    sid = owner["session_id"]
    assert state()["goal"]["objective"] == "UI revised objective"
    assert not selections, f"Keep paused prompt did not fire: {selections}"
    # Navigate the actual tree, declining a branch summary. Goal records remain
    # session-wide even when the selected conversation ancestry changes.
    selections.extend([0, 0])
    request("commands.run", {"line": "/tree"})
    assert state()["goal"]["objective"] == "UI revised objective"
    previous_rounds=state()["goal"]["rounds_started"]
    before_settled=len(settled_ids)
    temp = request("session.create", {"subscribe": False})
    request("session.close", {"session_id": source_id})
    selections.clear()
    selections.append(0)  # Explicitly accept the paused-goal resume prompt this time.
    owner = request("session.load", {"session_id": source_id, "subscribe": True})
    sid = owner["session_id"]
    request("session.close", {"session_id": temp["session_id"]})
    deadline=time.monotonic()+10
    while (
        state()["goal"]["rounds_started"] != previous_rounds + 1
        or state()["goal"]["status"] != "paused"
        or len(settled_ids) <= before_settled
    ):
        assert time.monotonic()<deadline
        time.sleep(0.01)
    request("agent.wait", {"session_id": sid, "turn_id": settled_ids[-1]})
    assert not selections, f"Resume paused goal prompt did not fire: {selections}"
    assert state()["goal"]["rounds_started"]==previous_rounds+1, (state(), previous_rounds, settled_ids, selections)
    before=state()
    selections.append(1)
    request("commands.run",{"line":"/goal cancelled replacement"})
    assert state()==before,"replacement cancellation changed the old goal"
    old_goal=state()["goal"]["id"]
    before_settled=len(settled_ids)
    selections.append(0)
    request("commands.run",{"line":"/goal accepted replacement"})
    deadline=time.monotonic()+10
    while state()["goal"]["status"]!="paused" or len(settled_ids)<=before_settled:
        assert time.monotonic()<deadline
        time.sleep(0.01)
    request("agent.wait", {"session_id": sid, "turn_id": settled_ids[-1]})
    fresh=state()["goal"]
    assert fresh["id"]!=old_goal and fresh["objective"]=="accepted replacement" and fresh["revision"]==2
    assert fresh.get("token_budget") is None and fresh["rounds_started"]==1
    check_readonly(owner["session_id"])
    assert state()["goal"]["id"]==fresh["id"],"readonly controller changed the writer's goal"
    request("commands.run", {"line": "/goal clear"})
    assert state()["cleared"] is True
    request("shutdown", {})
    assert process.wait(timeout=10) == 0
    print("mare-plugins: goal real RPC UI menu, form, cancel, edit, fork isolation, tree sharing, confirmed replacement and clear passed")
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
