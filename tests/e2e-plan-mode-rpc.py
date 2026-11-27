#!/usr/bin/env python3
"""Real JSON-RPC UI callbacks driving the same model tool and plan state machine."""
import json
import os
import pathlib
import queue
import shutil
import subprocess
import sys
import tempfile
import threading

repo = pathlib.Path(__file__).resolve().parents[1]
binary = pathlib.Path(os.environ.get("MARE_BIN", repo.parent / "mare/target/debug/mare"))


def start_line_reader(stream):
    lines = queue.Queue()

    def _read():
        while True:
            line = stream.readline()
            lines.put(line)
            if not line:
                break

    threading.Thread(target=_read, daemon=True).start()
    return lines


def read_line_timeout(lines, timeout, timeout_msg):
    try:
        return lines.get(timeout=timeout)
    except queue.Empty:
        raise AssertionError(timeout_msg)


def note_initialize(result):
    """Validate initialize reply carries capabilities.methods as a list."""
    methods = (result.get("capabilities") or {}).get("methods")
    assert isinstance(methods, list), ("initialize capabilities.methods is not a list", result)
    assert "agent.get" in methods, result
    return result


def current_sid(call):
    return call("status.get", {})["session"]["session_id"]


def agent_get(call):
    return call("agent.get", {"session_id": current_sid(call)})


def prompt_wait(call, text):
    sid = current_sid(call)
    started = call("agent.prompt", {"session_id": sid, "input": text})
    return call("agent.wait", {"session_id": sid, "turn_id": started["turn_id"]})


def plan_mode_state(call):
    return True, agent_get(call)["activity"]["extra"]["plan_mode"]


def check_plan(call, **expected):
    _, state = plan_mode_state(call)
    assert isinstance(state, dict), ("agent.get activity.extra.plan_mode is not an object", state)
    for key, value in expected.items():
        assert key in state and state[key] == value, (key, value, state)


def command_status(call, text):
    """commands.run returns {result?} on success and raises a coded error on failure;
    a command returning a {status} table carries it in result.status (e.g. "rejected"),
    while one returning nothing or a plain outcome on success is completed."""
    reply = call("commands.run", {"line": text})
    assert isinstance(reply, dict) and "ok" not in reply, (text, reply)
    result = reply.get("result")
    status = result.get("status") if isinstance(result, dict) else None
    return "completed" if status is None else status


def find_select_index(items, label):
    for idx, item in enumerate(items):
        if item.get("label") == label:
            return idx
    raise AssertionError(f"missing select item {label!r} in {items!r}")


def list_all_items(call, session_id):
    items, cursor = [], None
    while True:
        params = {"session_id": session_id}
        if cursor:
            params["cursor"] = cursor
        page = call("session.list_items", params)
        items.extend(page.get("data", []))
        cursor = page.get("next_cursor")
        if not cursor:
            return items


def read_ui_cards(call, session):
    """The session's ui/card records via session.list_records."""
    return call(
        "session.list_records",
        {"session_id": session["session_id"], "kind": "ui/card"},
    )["data"]


def prepare_sandbox(root, init_lua, with_effort_probe=False):
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
    config.mkdir(parents=True)
    (config / "init.lua").write_text(init_lua.format(package=package.as_uri()), encoding="utf-8")
    if with_effort_probe:
        plugins_dir = config / "plugins"
        plugins_dir.mkdir(parents=True, exist_ok=True)
        (plugins_dir / "g2g3-probe.lua").write_text(
            """return {
\tname = "g2g3-probe",
\tinject = { "llm", "session" },
\tapply = function(ctx)
\t\tctx:on("request/build", function(req, ev)
\t\t\tlocal path = mare.env.get("PLAN_EFFORT_CAPTURE")
\t\t\tif not path or path == "" then
\t\t\t\treturn ev.next(req)
\t\t\tend
\t\t\tlocal f = io.open(path, "a")
\t\t\tif f then
\t\t\t\tf:write(mare.json.encode({
\t\t\t\t\tsession_id = ctx.session:info().session_id,
\t\t\t\t\tmodel = req.model and req.model.ref or nil,
\t\t\t\t\teffort = ctx.llm:effort(),
\t\t\t\t\tactive_scope = ctx.llm.active_scope and ctx.llm:active_scope() or nil,
\t\t\t\t}) .. "\\n")
\t\t\t\tf:close()
\t\t\tend
\t\t\treturn ev.next(req)
\t\tend)
\tend,
}
""",
            encoding="utf-8",
        )


def scenario(answer):
    with tempfile.TemporaryDirectory(prefix="mare-plan-rpc-") as directory:
        root = pathlib.Path(directory)
        prepare_sandbox(
            root,
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
        )
        plan = "# Build the feature\n\nInspect the module, implement the change, then run the relevant checks."
        script = root / "script.json"
        responses = [
            {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]},
            {"text": "implementation acknowledged"},
        ]
        if answer == "steer":
            responses[1] = {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan + "\n\nIncorporate the new requirements."}}]}
        script.write_text(json.dumps(responses), encoding="utf-8")
        capture = root / "capture.jsonl"
        env = dict(os.environ, MARE_HOME=str(root / "home"), MARE_FAUX_SCRIPT=str(script), PLAN_CAPTURE=str(capture))
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
        stderr = (root / "stderr").open("w+")
        process = subprocess.Popen([str(binary), "--rpc", "--yolo"], env=env, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
        lines = start_line_reader(process.stdout)
        sequence = 0
        seen = []
        events = []
        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()
        def call(method, params, allow_error=False):
            nonlocal sequence
            sequence += 1
            request_id = sequence
            send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            while True:
                line = read_line_timeout(lines, 20, f"RPC timeout for {method}")
                if not line:
                    stderr.seek(0)
                    raise AssertionError("RPC exited: " + stderr.read())
                message = json.loads(line)
                if "method" in message:
                    events.append(message)
                    if "id" in message:
                        if message["method"] == "ui.select":
                            assert plan in "\n".join(message["params"].get("body", [])), message
                            items = message["params"].get("items", [])
                            seen.append("review")
                            if answer == "steer":
                                if seen.count("review") == 1:
                                    call("agent.steer", {"session_id": current_sid(call), "input": "New requirements invalidate that plan"})
                                    result = {"index": find_select_index(items, "Approve and implement")}
                                else:
                                    result = {"index": None}
                            elif answer == "cancel":
                                result = {"index": None}
                            else:
                                label = {"approve": "Approve and implement", "feedback": "Keep planning"}[answer]
                                result = {"index": find_select_index(items, label)}
                        elif message["method"] == "ui.input":
                            seen.append("feedback")
                            result = {"text": "Add a rollback strategy"}
                        elif message["method"] == "approval.request":
                            result = {"decision": "allow"}
                        else:
                            raise AssertionError(message)
                        send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                elif message.get("id") == request_id:
                    if allow_error:
                        return message
                    assert "error" not in message, message
                    return message.get("result")
        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            session = call("session.create", {})
            assert command_status(call, "/plan on") == "completed"
            check_plan(call, active=True)
            if answer == "approve":
                assert command_status(call, "/plan Prepare the complete plan") == "completed"
            else:
                run = prompt_wait(call, "Prepare the complete plan")
                # the turn ended normally (dismissed review: by terminate), not by an error
                assert "error" not in run and run.get("termination_reason") == "completed", run
            assert seen.count("review") == (2 if answer == "steer" else 1), seen
            requests = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
            assert requests[0]["active"] is True
            if answer == "approve":
                assert len(requests) == 2 and requests[1]["active"] is False, requests
                # Verify durable ui/card persisted in causal order and survives session.load.
                cards = read_ui_cards(call, session)
                assert len(cards) == 1, cards
                card = cards[0]
                assert card["kind"] == "proposed_plan" and card["title"] == "Proposed Plan" and card["markdown"] == plan, card
                entries = list_all_items(call, current_sid(call))
                assistant_exit = next(
                    e
                    for e in entries
                    if e.get("type") == "assistant_message"
                    and e.get("message", {}).get("role") == "assistant"
                    and any(b.get("name") == "exit_plan_mode" for b in e.get("message", {}).get("content", []))
                )
                assert card.get("after_entry_id") == assistant_exit.get("entry_id"), (card, assistant_exit)
                orig_id = current_sid(call)
                assert orig_id == session["session_id"], (orig_id, session)
                assert read_ui_cards(call, call("session.create", {})) == []
                resumed = call("session.load", {"session_id": orig_id})
                resumed_cards = read_ui_cards(call, resumed)
                assert resumed_cards == cards, (resumed_cards, cards)
            elif answer == "feedback":
                assert len(requests) == 2 and requests[1]["active"] is True, requests
                assert "feedback" in seen
            elif answer == "steer":
                assert len(requests) == 2 and all(item["active"] for item in requests), requests
                assert any("changed during review" in str(message) for message in requests[1]["messages"]), requests
            else:
                assert len(requests) == 1, requests
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()


for decision in ("approve", "feedback", "cancel", "steer"):
    scenario(decision)


def queued_batch_scenario(direction):
    with tempfile.TemporaryDirectory(prefix=f"mare-plan-rpc-{direction}-") as directory:
        root = pathlib.Path(directory)
        package = root / "package"
        (package / "plugins").mkdir(parents=True)
        import shutil
        shutil.copy(repo / "mare-plugin.toml", package)
        for source in (repo / "plugins/plan-mode", repo / "tests/fixtures/plan-mode-probe"):
            shutil.copytree(source, package / "plugins" / source.name)

        def git(*args):
            subprocess.run(["git", "-C", str(package), *args], check=True, capture_output=True)

        git("init", "-q", "-b", "main")
        git("add", "-A")
        git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        config = root / "home/config"
        config.mkdir(parents=True)
        (config / "init.lua").write_text('mare.setup {model="faux/echo"}\nmare.plugins.add {{"test/plan",url="' + package.as_uri() + '"}}\n', encoding="utf-8")
        plan = "# Batch plan\n\nVerify busy queued mode changes against committed batch state."
        script = root / "script.json"
        responses = [
            {
                "tool_calls": [
                    {"name": "bash", "arguments": {"command": "rm -f nonexistent.txt"}},
                    {"name": "exit_plan_mode", "arguments": {"plan": plan}},
                ]
            },
            {"text": "batch done"},
        ]
        script.write_text(json.dumps(responses), encoding="utf-8")
        capture = root / "capture.jsonl"
        env = dict(os.environ, MARE_HOME=str(root / "home"), MARE_FAUX_SCRIPT=str(script), PLAN_CAPTURE=str(capture))
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
        stderr = (root / "stderr").open("w+")
        process = subprocess.Popen([str(binary), "--rpc"], env=env, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
        lines = start_line_reader(process.stdout)
        sequence = 0
        seen = []
        queued = False

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def call(method, params):
            nonlocal sequence, queued
            sequence += 1
            request_id = sequence
            send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            while True:
                line = read_line_timeout(lines, 20, f"RPC timeout for {method}")
                if not line:
                    stderr.seek(0)
                    raise AssertionError("RPC exited: " + stderr.read())
                message = json.loads(line)
                if "method" in message and "id" in message:
                    if message["method"] == "approval.request":
                        if not queued:
                            queued = True
                            target = "on" if direction == "queued_on" else "off"
                            assert command_status(call, f"/plan {target}") == "completed"
                            if direction == "queued_on":
                                check_plan(call, active=False, pending=True)
                            else:
                                check_plan(call, active=True, pending=False)
                        result = {"decision": "allow"}
                    elif message["method"] == "ui.select":
                        seen.append("review")
                        result = {"index": find_select_index(message["params"].get("items", []), "Approve and implement")}
                    else:
                        raise AssertionError(message)
                    send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                elif message.get("id") == request_id:
                    assert "error" not in message, message
                    return message.get("result")

        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            if direction == "queued_on":
                assert command_status(call, "/plan on") == "completed"
                assert command_status(call, "/plan off") == "completed"
                check_plan(call, active=False)
            else:
                assert command_status(call, "/plan on") == "completed"
                check_plan(call, active=True)
            prompt_wait(call, "run tool batch")
            requests = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
            if direction == "queued_on":
                assert len(requests) >= 2, requests
                assert seen.count("review") == 0, seen
                assert requests[0]["active"] is False and requests[1]["active"] is True, requests
                assert any("only available in plan mode" in str(m) for m in requests[1]["messages"]), requests[1]["messages"]
            else:
                assert len(requests) == 2, requests
                assert seen.count("review") == 1, seen
                assert requests[0]["active"] is True and requests[1]["active"] is False, requests
                assert any("approved" in str(m) for m in requests[1]["messages"]), requests[1]["messages"]
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()


for direction in ("queued_on", "queued_off"):
    queued_batch_scenario(direction)


def clean_context_scenario():
    with tempfile.TemporaryDirectory(prefix="mare-plan-rpc-clean-") as directory:
        root = pathlib.Path(directory)
        init_lua = (
            'mare.setup {{model="faux/echo"}}\n'
            'mare.plugins.add {{{{"test/plan",url="{package}"}}}}\n'
            'mare.plugin("plan-mode", {{plan_effort="high", effort_scope="plan"}})\n'
        )
        prepare_sandbox(root, init_lua, with_effort_probe=True)
        plan = "# Clean Context Plan\n\n1. Inspect architecture\n2. Implement in fresh session\n3. Run verification"
        script = root / "script.json"
        script.write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]},
                    {"text": "clean implementation finished"},
                ]
            ),
            encoding="utf-8",
        )
        capture = root / "capture.jsonl"
        effort_capture = root / "effort.jsonl"
        env = dict(
            os.environ,
            MARE_HOME=str(root / "home"),
            MARE_FAUX_SCRIPT=str(script),
            PLAN_CAPTURE=str(capture),
            PLAN_EFFORT_CAPTURE=str(effort_capture),
        )
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
        stderr = (root / "stderr").open("w+")
        process = subprocess.Popen(
            [str(binary), "--rpc", "--yolo"],
            env=env,
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            bufsize=0,
        )
        lines = start_line_reader(process.stdout)
        sequence = 0
        seen = []
        seen_events = []
        transition_done = False
        transition_target_sid = None
        post_transition_end = False

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def read_msg():
            line = read_line_timeout(lines, 20, f"RPC timeout waiting for message; seen_events={seen_events!r}")
            if not line:
                stderr.seek(0)
                raise AssertionError("RPC exited: " + stderr.read())
            return json.loads(line)

        def handle_notification(message):
            nonlocal transition_done, transition_target_sid, post_transition_end
            if message.get("method") == "event":
                params = message.get("params", {})
                kind = params.get("type")
                seen_events.append(params)
                if kind == "session/transition-completed":
                    transition_done = True
                    target = params.get("data", {}).get("target") or {}
                    transition_target_sid = target.get("session_id") or target.get("id")
                    if params.get("data", {}).get("initial_status") == "settled":
                        post_transition_end = True
                elif kind == "turn/completed" and transition_done:
                    ev_sid = params.get("session_id")
                    if transition_target_sid is None or ev_sid == transition_target_sid:
                        post_transition_end = True

        def call(method, params):
            nonlocal sequence
            sequence += 1
            request_id = sequence
            send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            while True:
                message = read_msg()
                if "method" in message:
                    handle_notification(message)
                    if "id" in message:
                        if message["method"] == "ui.select":
                            seen.append("review")
                            items = message["params"].get("items", [])
                            result = {"index": find_select_index(items, "Implement plan cleanly (clear context)")}
                        else:
                            raise AssertionError(message)
                        send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                elif message.get("id") == request_id:
                    assert "error" not in message, message
                    return message.get("result")

        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            call("events.subscribe", {"scope": "all", "include": ["session/*", "turn/*", "status/*", "plan-mode/*"]})
            assert agent_get(call)["effort"] == "medium"
            orig_id = current_sid(call)
            assert command_status(call, "/plan on") == "completed"
            assert agent_get(call)["effort"] == "high"
            call("agent.prompt", {"session_id": orig_id, "input": "Prepare clean plan"})
            while not (transition_done and post_transition_end):
                message = read_msg()
                if "method" in message:
                    handle_notification(message)
                    if "id" in message:
                        if message["method"] == "ui.select":
                            seen.append("review")
                            items = message["params"].get("items", [])
                            result = {"index": find_select_index(items, "Implement plan cleanly (clear context)")}
                            send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                        else:
                            raise AssertionError(message)
            new_state = agent_get(call)
            assert new_state["session_id"] != orig_id, (new_state, orig_id)
            assert new_state["effort"] == "medium", new_state
            check_plan(call, active=False, plan=plan)
            requests = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
            efforts = [json.loads(line) for line in effort_capture.read_text(encoding="utf-8").splitlines()]
            assert len(requests) == 2 and len(efforts) == 2, (requests, efforts)
            assert requests[0]["active"] is True and efforts[0]["effort"] == "high" and efforts[0].get("active_scope") == "plan"
            assert requests[1]["active"] is False and efforts[1]["effort"] == "medium" and efforts[1].get("active_scope") is None
            assert efforts[1]["session_id"] == new_state["session_id"]
            non_notif = [m for m in requests[1]["messages"] if not m.get("notification")]
            notif_msgs = [m for m in requests[1]["messages"] if m.get("notification")]
            assert len(non_notif) == 1, requests[1]["messages"]
            assert all("Prepare clean plan" not in json.dumps(m) for m in notif_msgs), notif_msgs
            msg_text = non_notif[0]["content"][0]["text"]
            assert "Implement the following approved plan" in msg_text and plan in msg_text, msg_text
            # Verify source session kept the durable Proposed Plan ui/card on load
            cards = read_ui_cards(call, call("session.load", {"session_id": orig_id}))
            assert len(cards) == 1 and cards[0]["markdown"] == plan and cards[0]["kind"] == "proposed_plan", cards
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()


def effort_commands_scenario():
    with tempfile.TemporaryDirectory(prefix="mare-plan-rpc-effort-") as directory:
        root = pathlib.Path(directory)
        prepare_sandbox(
            root,
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
        )
        alt_dir = root / "home/config/plugins"
        alt_dir.mkdir(parents=True, exist_ok=True)
        (alt_dir / "alt-model.lua").write_text(
            """return {
\tname = "alt-model",
\tinject = { "llm" },
\tapply = function(ctx)
\t\tctx.llm:register_provider({
\t\t\tprovider = "alt",
\t\t\tdefault_model = "model",
\t\t\tis_configured = function() return true end,
\t\t\tmodels = {
\t\t\t\t{ model_id = "model", name = "Alt Model", context_window = 100000, max_output = 4096, reasoning = true, efforts = { "low", "medium", "high", "xhigh" } },
\t\t\t},
\t\t\tstream = function() return { role = "assistant", content = { { type = "text", text = "ok" } }, stop_reason = "stop" } end,
\t\t})
\tend,
}
""",
            encoding="utf-8",
        )
        env = dict(os.environ, MARE_HOME=str(root / "home"))
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)

        def start_rpc():
            stderr = (root / "stderr").open("w+")
            proc = subprocess.Popen(
                [str(binary), "--rpc", "--yolo"],
                env=env,
                cwd=root,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr,
                bufsize=0,
            )
            lines = start_line_reader(proc.stdout)
            seq = 0

            def call_rpc(method, params, allow_error=False):
                nonlocal seq
                seq += 1
                request_id = seq
                proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n").encode())
                proc.stdin.flush()
                while True:
                    line = read_line_timeout(lines, 20, f"RPC timeout for {method}")
                    if not line:
                        stderr.seek(0)
                        raise AssertionError("RPC exited: " + stderr.read())
                    message = json.loads(line)
                    if message.get("id") == request_id:
                        if allow_error:
                            return message
                        assert "error" not in message, message
                        return message.get("result")

            return proc, stderr, call_rpc

        process, stderr, call = start_rpc()
        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            assert agent_get(call)["effort"] == "medium"
            assert command_status(call, "/plan on") == "completed"
            assert command_status(call, "/plan effort status") == "completed"
            assert command_status(call, "/plan effort low") == "completed"
            assert agent_get(call)["effort"] == "low"
            assert command_status(call, "/plan effort bogus") == "rejected"
            # Temporary --session applies now without overwriting persisted "low"
            assert command_status(call, "/plan effort high --session") == "completed"
            assert agent_get(call)["effort"] == "high"
            assert command_status(call, "/plan off") == "completed"
            assert agent_get(call)["effort"] == "medium"
            # Switch to alt/model: must not inherit faux/echo's plan effort; persist xhigh globally
            assert command_status(call, "/model alt/model") == "completed"
            assert agent_get(call)["effort"] == "medium"
            assert command_status(call, "/plan on") == "completed"
            assert agent_get(call)["effort"] == "medium"
            assert command_status(call, "/plan effort xhigh global") == "completed"
            assert agent_get(call)["effort"] == "xhigh"
            assert command_status(call, "/plan effort low global --session") == "completed"
            assert agent_get(call)["effort"] == "low"
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()

        # Restart process against same MARE_HOME and verify per-model persisted plan & global effort
        process2, stderr2, call2 = start_rpc()
        try:
            note_initialize(call2("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            assert agent_get(call2)["effort"] == "medium"
            assert command_status(call2, "/plan on") == "completed"
            assert agent_get(call2)["effort"] == "low", "faux/echo persisted plan effort across restart"
            assert command_status(call2, "/plan off") == "completed"
            assert agent_get(call2)["effort"] == "medium"
            assert command_status(call2, "/model alt/model") == "completed"
            assert agent_get(call2)["effort"] == "xhigh", "alt/model persisted global effort across restart"
            assert command_status(call2, "/plan on") == "completed"
            assert agent_get(call2)["effort"] == "xhigh", "alt/model persisted plan effort across restart"
            assert command_status(call2, "/plan effort clear") == "completed"
            assert command_status(call2, "/plan off") == "completed"
            assert agent_get(call2)["effort"] == "xhigh"
            call2("shutdown", {})
        finally:
            process2.terminate()
            process2.wait(timeout=5)
            stderr2.close()


def default_permissions_scenario():
    with tempfile.TemporaryDirectory(prefix="mare-plan-rpc-perms-") as directory:
        root = pathlib.Path(directory)
        prepare_sandbox(
            root,
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
        )
        plan = "# Default Permissions Plan\n\nVerify non-yolo review flow and refusal."
        script = root / "script.json"
        script.write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]},
                    {"text": "auto approved"},
                    {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]},
                    {"text": "denied once"},
                    {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]},
                    {"text": "allowed after approval"},
                ]
            ),
            encoding="utf-8",
        )
        capture = root / "capture.jsonl"
        env = dict(os.environ, MARE_HOME=str(root / "home"), MARE_FAUX_SCRIPT=str(script), PLAN_CAPTURE=str(capture))
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
        subprocess.run([str(binary), "trust"], env=env, cwd=root, check=True, capture_output=True)
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
        lines = start_line_reader(process.stdout)
        sequence = 0
        approvals = []
        reviews = []
        approval_decision = "allow"

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def call(method, params):
            nonlocal sequence
            sequence += 1
            request_id = sequence
            send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            while True:
                line = read_line_timeout(lines, 20, f"RPC timeout for {method}")
                if not line:
                    stderr.seek(0)
                    raise AssertionError("RPC exited: " + stderr.read())
                message = json.loads(line)
                if "method" in message and "id" in message:
                    if message["method"] == "approval.request":
                        approvals.append(message["params"])
                        result = {"decision": approval_decision}
                    elif message["method"] == "ui.select":
                        reviews.append(message["params"])
                        items = message["params"].get("items", [])
                        result = {"index": find_select_index(items, "Approve and implement")}
                    else:
                        raise AssertionError(message)
                    send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                elif message.get("id") == request_id:
                    assert "error" not in message, message
                    return message.get("result")

        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            # 1. Default non-yolo (auto preset): exit_plan_mode proceeds to ui.select without tool approval prompt.
            assert command_status(call, "/plan on") == "completed"
            prompt_wait(call, "auto review")
            assert len(approvals) == 0, approvals
            assert len(reviews) == 1
            check_plan(call, active=False)

            # 2. Read-only preset (non-yolo): exit_plan_mode requires approval; deny blocks review cleanly.
            assert command_status(call, "/permission read-only") == "completed"
            assert command_status(call, "/plan on") == "completed"
            approval_decision = "deny"
            prompt_wait(call, "readonly deny")
            assert len(approvals) == 1 and approvals[0]["tool"] == "exit_plan_mode", approvals
            assert len(reviews) == 1, "denied exit_plan_mode must not open ui.select"
            check_plan(call, active=True)

            # 3. Approving exit_plan_mode under read-only proceeds to ui.select and exits plan mode.
            approval_decision = "allow"
            prompt_wait(call, "readonly allow")
            assert len(approvals) == 2 and approvals[1]["tool"] == "exit_plan_mode", approvals
            assert len(reviews) == 2
            check_plan(call, active=False)
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()


def idle_narration_and_empty_feedback_scenario():
    with tempfile.TemporaryDirectory(prefix="mare-plan-rpc-narr-") as directory:
        root = pathlib.Path(directory)
        prepare_sandbox(
            root,
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
        )
        plan = "# Draft plan\n\nStep 1: verify."
        script = root / "script.json"
        script.write_text(
            json.dumps(
                [
                    {"text": "regular turn while plan mode inactive"},
                    {"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]},
                    {"text": "revised plan placeholder"},
                    {"text": "after exiting plan mode"},
                ]
            ),
            encoding="utf-8",
        )
        capture = root / "capture.jsonl"
        env = dict(os.environ, MARE_HOME=str(root / "home"), MARE_FAUX_SCRIPT=str(script), PLAN_CAPTURE=str(capture))
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
        stderr = (root / "stderr").open("w+")
        process = subprocess.Popen([str(binary), "--rpc", "--yolo"], env=env, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
        lines = start_line_reader(process.stdout)
        sequence = 0

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def call(method, params):
            nonlocal sequence
            sequence += 1
            request_id = sequence
            send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            while True:
                line = read_line_timeout(lines, 20, f"RPC timeout for {method}")
                if not line:
                    stderr.seek(0)
                    raise AssertionError("RPC exited: " + stderr.read())
                message = json.loads(line)
                if "method" in message:
                    if "id" in message:
                        if message["method"] == "ui.select":
                            items = message["params"].get("items", [])
                            result = {"index": find_select_index(items, "Keep planning")}
                        elif message["method"] == "ui.input":
                            result = {"text": ""}
                        else:
                            raise AssertionError(message)
                        send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                elif message.get("id") == request_id:
                    assert "error" not in message, message
                    return message.get("result")

        def message_texts(req):
            return [block.get("text", "") for m in req.get("messages", []) for block in m.get("content", []) if isinstance(block, dict)]

        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            # 1. Request 0 runs with plan mode inactive (records last_request_active=false).
            prompt_wait(call, "baseline off")
            # 2. Idle toggle on -> subsequent request sees switched-on narration.
            assert command_status(call, "/plan on") == "completed"
            prompt_wait(call, "make a plan")
            # 3. exit_plan_mode chose Keep planning with empty ui.input -> generic revision message, active remains True.
            check_plan(call, active=True)
            # 4. Idle toggle off -> subsequent request sees switched-off narration.
            assert command_status(call, "/plan off") == "completed"
            prompt_wait(call, "normal prompt again")
            check_plan(call, active=False)

            requests = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
            assert len(requests) == 4, requests
            assert requests[0]["active"] is False
            assert requests[1]["active"] is True
            assert any("The user switched plan mode on." in t for t in message_texts(requests[1])), requests[1]
            assert requests[2]["active"] is True
            assert any("The user chose to keep planning; revise the plan and present it again." in t for t in message_texts(requests[2])), requests[2]
            assert requests[3]["active"] is False
            assert any("The user switched plan mode off." in t for t in message_texts(requests[3])), requests[3]
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()


def clean_context_abort_scenario():
    with tempfile.TemporaryDirectory(prefix="mare-plan-rpc-abort-") as directory:
        root = pathlib.Path(directory)
        prepare_sandbox(
            root,
            'mare.setup {{model="faux/echo"}}\nmare.plugins.add {{{{"test/plan",url="{package}"}}}}\n',
        )
        hook_dir = root / "home/config/plugins"
        hook_dir.mkdir(parents=True, exist_ok=True)
        (hook_dir / "abort-after-approve.lua").write_text(
            """return {
\tname = "abort-after-approve",
\tinject = { "agent" },
\tapply = function(ctx)
\t\tctx:on("tool/after", function(data, ev)
\t\t\tlocal result, call = data.result, data.call
\t\t\tif call and call.name == "exit_plan_mode" and result and not result.is_error then
\t\t\t\tctx.agent:cancel({ reason = "user" })
\t\t\tend
\t\t\treturn ev.next(data)
\t\tend)
\tend,
}
""",
            encoding="utf-8",
        )
        plan = "# Abortable Clean Plan\n\nVerify turn abort before agent/settled cancels handoff."
        script = root / "script.json"
        script.write_text(json.dumps([{"tool_calls": [{"name": "exit_plan_mode", "arguments": {"plan": plan}}]}]), encoding="utf-8")
        # the probe's request/build listener records every request to PLAN_CAPTURE
        env = dict(os.environ, MARE_HOME=str(root / "home"), MARE_FAUX_SCRIPT=str(script), PLAN_CAPTURE=str(root / "capture.jsonl"))
        subprocess.run([str(binary), "plugin", "sync"], env=env, cwd=root, check=True, capture_output=True)
        stderr = (root / "stderr").open("w+")
        process = subprocess.Popen([str(binary), "--rpc", "--yolo"], env=env, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
        lines = start_line_reader(process.stdout)
        sequence = 0
        seen_events = []
        settled = False

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def read_msg():
            line = read_line_timeout(lines, 20, f"RPC timeout; seen_events={seen_events!r}")
            if not line:
                stderr.seek(0)
                raise AssertionError("RPC exited: " + stderr.read())
            return json.loads(line)

        def record_event(message):
            nonlocal settled
            if message.get("method") == "event":
                params = message.get("params", {})
                seen_events.append(params)
                if params.get("type") == "turn/completed":
                    settled = True

        def call(method, params):
            nonlocal sequence
            sequence += 1
            request_id = sequence
            send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            while True:
                message = read_msg()
                if "method" in message:
                    record_event(message)
                    if "id" in message:
                        assert message["method"] == "ui.select", message
                        items = message["params"].get("items", [])
                        send({"jsonrpc": "2.0", "id": message["id"], "result": {"index": find_select_index(items, "Implement plan cleanly (clear context)")}})
                elif message.get("id") == request_id:
                    assert "error" not in message, message
                    return message.get("result")

        try:
            note_initialize(call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True, "approvals": True}}))
            call("events.subscribe", {"scope": "all", "include": ["session/*", "turn/*", "status/*"]})
            orig_id = current_sid(call)
            assert command_status(call, "/plan on") == "completed"
            call("agent.prompt", {"session_id": orig_id, "input": "Clean plan then abort turn"})
            while not settled:
                message = read_msg()
                if "method" in message:
                    record_event(message)
                    if "id" in message:
                        if message["method"] == "ui.select":
                            items = message["params"].get("items", [])
                            send({"jsonrpc": "2.0", "id": message["id"], "result": {"index": find_select_index(items, "Implement plan cleanly (clear context)")}})
                        else:
                            raise AssertionError(message)
            # Yield one settled follow-up RPC so deferred microtask has drained before asserting
            assert current_sid(call) == orig_id
            types = [e.get("type") for e in seen_events]
            assert "session/transition-completed" not in types, seen_events
            failed = [e for e in seen_events if e.get("type") == "session/transition-failed"]
            assert len(failed) == 1 and "cancelled" in str(failed[0].get("data", {}).get("error", "")), seen_events
            check_plan(call, active=True)
            call("shutdown", {})
        finally:
            process.terminate()
            process.wait(timeout=5)
            stderr.close()


clean_context_scenario()
clean_context_abort_scenario()
effort_commands_scenario()
default_permissions_scenario()
idle_narration_and_empty_feedback_scenario()
print("plan-mode real RPC UI: approval, feedback, dismissal, steer invalidation, queued selections, clean-context review, effort, durable cards, default non-yolo permissions, and idle narration/empty feedback passed")
