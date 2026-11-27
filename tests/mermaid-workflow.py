#!/usr/bin/env python3
"""Installed file:// Mermaid plugin, real guarded producer, actual mmdc PNG and replay."""

import base64
import hashlib
import json
import os
import pathlib
import queue
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Client:
    def __init__(self, binary, home, work, args=None, config=None, prompt_rule=False):
        self.home = home
        directory = home / "config"
        directory.mkdir(parents=True, exist_ok=True)
        package = home / "package"
        (package / "plugins").mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "mare-plugin.toml", package / "mare-plugin.toml")
        shutil.copytree(
            ROOT / "plugins" / "mermaid",
            package / "plugins" / "mermaid",
            dirs_exist_ok=True,
        )
        if not (package / ".git").exists():
            for git_args in (
                ["init", "-q", "-b", "main"],
                ["add", "mare-plugin.toml", "plugins/mermaid"],
                [
                    "-c",
                    "user.name=fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "fixture",
                ],
            ):
                git_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
                subprocess.run(
                    ["git", "-C", str(package), *git_args],
                    check=True,
                    capture_output=True,
                    env=git_env,
                )
        # JSON literals here are a strict subset of Lua for the string/number options used.
        options = ",".join(
            f"{key}={json.dumps(value)}" for key, value in (config or {}).items()
        )
        (directory / "init.lua").write_text(
            (
                "mare.setup {model='faux/echo',plugins={permissions={rules={{tool='mermaid',decision='prompt'}}}}}\n"
                if prompt_rule
                else "mare.setup {model='faux/echo'}\n"
            )
            + f"mare.plugins.add {{{{ 'test/mermaid',url={json.dumps(package.as_uri())},opts={{mermaid={{{options}}}}} }}}}\n",
            encoding="utf-8",
        )
        script = home / "faux.json"
        script.write_text("[]", encoding="utf-8")
        env = dict(os.environ, MARE_HOME=str(home), MARE_FAUX_SCRIPT=str(script))
        subprocess.run(
            [str(binary), "plugin", "sync"],
            cwd=work,
            env=env,
            check=True,
            capture_output=True,
        )
        self.process = subprocess.Popen(
            [str(binary), "--rpc", "--model", "faux/echo", *(args or ["--yolo"])],
            cwd=work,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            encoding="utf-8",
        )
        self.lines, self.errors, self.notifications = queue.Queue(), [], []
        threading.Thread(target=self.read_stdout, daemon=True).start()
        threading.Thread(target=self.read_stderr, daemon=True).start()
        self.sequence = 0
        self.approvals = []
        self.approve = "deny"
        self.loaded_path = None
        init = self.call(
            "initialize",
            {
                "protocol_version": "3.0",
                "capabilities": {"approvals": True, "ui": True, "uiContexts": True},
            },
        )
        self.session_id = init["session"]["session_id"]

    def read_stdout(self):
        for line in self.process.stdout:
            self.lines.put(json.loads(line))
        self.lines.put(None)

    def read_stderr(self):
        self.errors.extend(self.process.stderr)

    def send(self, value):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", **value}) + "\n")
        self.process.stdin.flush()

    def call(self, method, params=None, timeout=45, allow_error=False):
        self.sequence += 1
        identity = self.sequence
        self.send({"id": identity, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            message = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            assert message is not None, "Mare exited: " + "".join(self.errors)[-4000:]
            if message.get("method") == "approval.request":
                self.approvals.append(message["params"])
                self.send(
                    {
                        "id": message["id"],
                        "uiContextId": message.get("uiContextId", 0),
                        "result": {"decision": self.approve},
                    }
                )
            elif message.get("method") in ("ui.select", "ui.input", "ui.confirm"):
                answer = {}
                if message["method"] == "ui.select":
                    for index, item in enumerate(message["params"]["items"]):
                        if item["label"] == "View read-only":
                            answer = {"index": index}
                self.send(
                    {
                        "id": message["id"],
                        "uiContextId": message.get("uiContextId", 0),
                        "result": answer,
                    }
                )
            elif message.get("id") == identity:
                if allow_error:
                    return message
                assert "error" not in message, message
                res = message["result"]
                if (
                    method in ("session.load", "session.create", "session.fork")
                    and isinstance(res, dict)
                    and (res.get("session_id") or res.get("id"))
                ):
                    self.session_id = res.get("session_id") or res.get("id")
                    if method == "session.load" and isinstance(params, dict) and params.get("path"):
                        self.loaded_path = params["path"]
                    elif method != "session.load":
                        self.loaded_path = None
                return res
            else:
                self.notifications.append(message)

    def settled(self, identity, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.call(
                "ui.get_markdown",
                {"session_id": self.session_id, "document_id": identity},
            )
            if result and result["pending"] == 0:
                return result
            time.sleep(0.02)
        raise AssertionError("producer did not settle: " + "".join(self.errors)[-4000:])

    def present(self, identity, source, images=True):
        self.call(
            "ui.render_markdown",
            {
                "session_id": self.session_id,
                "document_id": identity,
                "source": source,
                "viewport": {
                    "width": 80,
                    "height": 30,
                    "supports_images": images,
                    "supports_artifact_images": images,
                },
            },
        )
        return self.settled(identity)

    def entries(self):
        sessions = self.call("session.list")["data"]
        matches = [
            entry
            for entry in sessions
            if entry.get("session_id") == self.session_id or entry.get("id") == self.session_id
        ]
        if matches:
            assert len(matches) == 1, (self.session_id, matches)
            path = matches[0].get("path") or matches[0].get("file") or self.loaded_path
            assert path, (self.session_id, matches[0])
            target = pathlib.Path(path)
            if not target.exists():
                raise AssertionError(
                    f"session {self.session_id} listed at missing journal {target}"
                )
        elif self.loaded_path:
            target = pathlib.Path(self.loaded_path)
            if not target.exists():
                return []
        else:
            info = self.call("session.get", {"session_id": self.session_id})
            path = info.get("path") or info.get("file")
            if not path:
                return []
            target = pathlib.Path(path)
            if not target.exists():
                if info.get("leaf_entry_id"):
                    raise AssertionError(
                        f"session {self.session_id} has leaf {info['leaf_entry_id']} but missing journal {target}"
                    )
                return []
        rows = []
        for line in target.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
        return rows

    def records(self, kind, snapshot):
        return self.call(
            "session.list_records",
            {
                "kind": kind,
                "session_id": snapshot.get("session_id") or self.session_id,
            },
        )["data"]

    def close(self):
        if self.process.poll() is None:
            try:
                self.call("shutdown", timeout=10)
                self.process.stdin.close()
                self.process.wait(timeout=10)
            except (OSError, AssertionError, queue.Empty, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=10)


def image_nodes(node):
    if isinstance(node, list):
        for value in node:
            yield from image_nodes(value)
    elif isinstance(node, dict):
        if node.get("type") == "image":
            yield node
        for value in node.values():
            yield from image_nodes(value)


def main():
    binary = pathlib.Path(
        os.environ.get("MARE_BIN", ROOT.parent / "mare" / "target" / "debug" / "mare")
    ).resolve()
    assert binary.is_file(), "set MARE_BIN to the matching core executable"
    if not (shutil.which("mmdc") and shutil.which("node")):
        print("SKIPPED[capability=bin.mmdc] actual producer test requires existing mmdc >=12 and Node; nothing is installed")
        sys.exit(77)
    with tempfile.TemporaryDirectory(prefix="mermaid-producer-") as directory:
        directory = pathlib.Path(directory).resolve()
        home, work = directory / "home", directory / "work"
        work.mkdir()
        client = Client(binary, home, work)
        source = "before\n\n```mermaid\ngraph TD\nA[开始]-->B[完成]\n```\n\nafter"
        try:
            presenters = client.call("ui.list_markdown_presenters")["data"]
            assert presenters, (
                "installed Mermaid presenter failed to register"
            )
            result = client.present("actual", source)
            assert result["enhanced"], (result, client.errors)
            images = list(image_nodes(result["node"]))
            assert len(images) == 1
            assert "data" not in images[0], "history retained inline PNG"
            resource = images[0]["resource"]
            assert "resolver_id" not in resource
            image_ref = json.loads(resource["key"])
            png = base64.b64decode(
                client.call(
                    "spill.read",
                    {
                        "session_id": image_ref["session_id"],
                        "spill_id": image_ref["spill_id"],
                        "encoding": "base64",
                    },
                )["data_base64"],
                validate=True,
            )
            assert hashlib.sha256(png).hexdigest() == image_ref["sha256"]
            width, height = struct.unpack(">II", png[16:24])
            assert png[:8] == b"\x89PNG\r\n\x1a\n" and width > 32 and height > 32
            artifacts = client.records("mermaid/artifact", result)
            assert len(artifacts) == 1 and re.match(
                r"^(?:1[2-9]|[2-9]\d+)\.", artifacts[0]["renderer"]
            ), artifacts
            assert (
                base64.b64decode(
                    client.call(
                        "spill.read",
                        {
                            "session_id": image_ref["session_id"],
                            "spill_id": artifacts[0]["spill_id"],
                            "encoding": "base64",
                        },
                    )["data_base64"],
                    validate=True,
                )
                == png
            )
            states = [
                entry for entry in client.entries() if entry.get("type") == "tool_state"
            ]
            assert [entry["state"] for entry in states] == [
                "prepared",
                "started",
                "completed",
            ]
            assert not client.call("agent.list_messages", {"session_id": client.session_id})["data"], (
                "automatic producer must not synthesize model tool messages"
            )
            sessions = client.call("session.list")["data"]
            session_path = next(
                entry.get("path", entry.get("file"))
                for entry in sessions
                if entry.get("path", entry.get("file"))
            )
            legacy_source = (
                "```mermaid\ngraph TD\nLEGACY[no artifact support]-->END\n```"
            )
            client.call(
                "ui.render_markdown",
                {
                    "session_id": client.session_id,
                    "document_id": "legacy-image-client",
                    "source": legacy_source,
                    "viewport": {"width": 80, "supports_images": True},
                },
            )
            legacy = client.settled("legacy-image-client")
            assert (
                not legacy["enhanced"]
                and legacy["source"] == legacy_source
                and "artifact" in legacy["diagnostic"]
            )
            no_images = client.present("no-images", source, images=False)
            assert no_images["source"] == source and not no_images["enhanced"]
            assert (
                len(
                    [
                        entry
                        for entry in client.entries()
                        if entry.get("type") == "tool_state"
                    ]
                )
                == 3
            )
            cancelled_source = (
                "```mermaid\ngraph TD\nC[cancel this actual renderer]-->D\n```"
            )
            client.call(
                "ui.render_markdown",
                {
                    "session_id": client.session_id,
                    "document_id": "cancel",
                    "source": cancelled_source,
                    "viewport": {
                        "width": 80,
                        "supports_images": True,
                        "supports_artifact_images": True,
                    },
                },
            )
            deadline = time.monotonic() + 15
            while not any(
                entry.get("state") == "started"
                and entry.get("tool_call_id") not in {state["tool_call_id"] for state in states}
                for entry in client.entries()
            ):
                assert time.monotonic() < deadline, (
                    "actual renderer did not start before cancellation"
                )
                time.sleep(0.01)
            client.call(
                "ui.cancel_markdown",
                {"session_id": client.session_id, "document_id": "cancel"},
            )
            cancelled = client.settled("cancel")
            assert not cancelled["enhanced"] and cancelled["source"] == cancelled_source
            time.sleep(0.2)
            assert len(client.records("mermaid/artifact", cancelled)) == 1
            bad_source = "```mermaid\nflowchart TD\nA[broken\n```"
            failed = client.present("syntax", bad_source)
            assert failed["source"] == bad_source and not failed["enhanced"]
            assert len(client.records("mermaid/artifact", failed)) == 1
            trace = os.environ.get("MERMAID_TRACE_DIR")
            if trace:
                target = pathlib.Path(trace)
                target.mkdir(parents=True, exist_ok=True)
                (target / "actual-mermaid.png").write_bytes(png)
                (target / "actual-snapshot.json").write_text(
                    json.dumps(result, ensure_ascii=False), encoding="utf-8"
                )
                (target / "journal-before-resume.json").write_text(
                    json.dumps(client.entries(), ensure_ascii=False), encoding="utf-8"
                )
        finally:
            client.close()
        resumed = Client(binary, home, work)
        try:
            resumed.call("session.load", {"path": session_path})
            before_states = len(
                [
                    entry
                    for entry in resumed.entries()
                    if entry.get("type") == "tool_state"
                ]
            )
            restored = resumed.present("restored", source)
            assert restored["enhanced"]
            assert (
                len(
                    [
                        entry
                        for entry in resumed.entries()
                        if entry.get("type") == "tool_state"
                    ]
                )
                == before_states
            ), "resume must rematerialize saved artifact without launching renderer"
            client_entries_before_switch = resumed.entries()
            switch_source = "```mermaid\ngraph TD\nX[owner switch]-->Y\n```"
            resumed.call(
                "ui.render_markdown",
                {
                    "session_id": resumed.session_id,
                    "document_id": "owner-switch",
                    "source": switch_source,
                    "viewport": {
                        "width": 80,
                        "supports_images": True,
                        "supports_artifact_images": True,
                    },
                },
            )
            deadline = time.monotonic() + 15
            while len(
                [
                    entry
                    for entry in resumed.entries()
                    if entry.get("state") == "started"
                ]
            ) <= len(
                [
                    entry
                    for entry in client_entries_before_switch
                    if entry.get("state") == "started"
                ]
            ):
                assert time.monotonic() < deadline, (
                    "renderer did not start before owner switch"
                )
                time.sleep(0.01)
            resumed.call("session.create")
            time.sleep(0.2)
            missing = resumed.call(
                "ui.get_markdown",
                {"session_id": resumed.session_id, "document_id": "owner-switch"},
                allow_error=True,
            )
            assert missing.get("error", {}).get("data", {}).get("code") == "ui.unknown_document", missing
            assert not resumed.records("mermaid/artifact", {"session_id": resumed.session_id})
        finally:
            resumed.close()
    # A real approval frontend makes the normal external-tool decision. No global
    # terminal capabilities, mode or process implementation is patched.
    with tempfile.TemporaryDirectory(prefix="mermaid-policy-") as directory:
        directory = pathlib.Path(directory)
        work = directory / "work"
        work.mkdir()
        policy = Client(
            binary,
            directory / "home",
            work,
            args=["--permission", "auto"],
            prompt_rule=True,
        )
        try:
            rejected = policy.present("denied", source)
            assert policy.approvals, "external renderer bypassed normal approval"
            assert rejected["source"] == source and not rejected["enhanced"]
            assert not policy.records("mermaid/artifact", rejected)
            assert not [
                entry for entry in policy.entries() if entry.get("state") == "started"
            ]
            policy.approve = "allow"
            allowed = policy.present("allowed", source)
            allowed_states = [
                entry["state"]
                for entry in policy.entries()
                if entry.get("type") == "tool_state"
            ]
            assert allowed_states[-3:] == ["prepared", "started", "completed"]
            if not allowed["enhanced"]:
                # Browser launch can legitimately be refused by the current sandbox.
                # Require the actual failure and complete source, never count it as PNG.
                failures = policy.records("mermaid/result", allowed)
                assert failures[-1]["result"]["is_error"]
                assert "Mermaid source:" in failures[-1]["result"]["content"]
                assert allowed["source"] == source
                assert not policy.records("mermaid/artifact", allowed)
        finally:
            policy.close()
        held = Client(binary, directory / "held", work)
        readonly = Client(binary, directory / "readonly", work)
        try:
            held_result = held.present("held", source)
            assert held_result["enhanced"], (
                held_result,
                held.records("mermaid/result", held_result),
                held.errors,
            )
            held_states = [
                entry for entry in held.entries() if entry.get("type") == "tool_state"
            ]
            path = next(
                entry.get("path", entry.get("file"))
                for entry in held.call("session.list")["data"]
            )
            before_file = pathlib.Path(path).read_bytes()
            readonly.call("session.load", {"path": path})
            readonly_source = "```mermaid\ngraph TD\nR[uncached readonly]-->S\n```"
            refused = readonly.present("readonly", readonly_source)
            assert not refused["enhanced"] and refused["source"] == readonly_source
            assert not readonly.approvals
            assert [
                entry
                for entry in readonly.entries()
                if entry.get("type") == "tool_state"
            ] == held_states
            assert pathlib.Path(path).read_bytes() == before_file
        finally:
            readonly.close()
            held.close()
        dedup_client = Client(binary, directory / "dedup", work)
        try:
            dedup_source = (
                "```lua\nreturn 1\n```\n\n"
                "```MERMAID theme=dark\ngraph TD\nDUP[same]-->END\n```\n\n"
                '```mmd title="second"\ngraph TD\nDUP[same]-->END\n```'
            )
            dedup_result = dedup_client.present("dedup-case-info", dedup_source)
            assert dedup_result["enhanced"], (dedup_result, dedup_client.errors)
            dedup_images = list(image_nodes(dedup_result["node"]))
            assert len(dedup_images) == 2, dedup_images
            assert len(dedup_client.records("mermaid/artifact", dedup_result)) == 1
            dedup_states = [
                entry
                for entry in dedup_client.entries()
                if entry.get("type") == "tool_state"
            ]
            assert [entry["state"] for entry in dedup_states] == [
                "prepared",
                "started",
                "completed",
            ]
        finally:
            dedup_client.close()
        missing = Client(
            binary,
            directory / "missing-mmdc",
            work,
            config={"command": "nonexistent-mmdc-binary"},
        )
        try:
            missing_source = "```mmd\ngraph TD\nMISSING[fallback]-->END\n```"
            missing_result = missing.present("missing", missing_source)
            assert (
                not missing_result["enhanced"]
                and missing_result["source"] == missing_source
            )
            assert not missing.records("mermaid/artifact", missing_result)
            missing_results = missing.records("mermaid/result", missing_result)
            assert len(missing_results) == 1
            assert missing_results[0]["result"]["is_error"]
            assert "renderer failed:" in missing_results[0]["result"]["content"]
            assert "Mermaid source:" in missing_results[0]["result"]["content"]
        finally:
            missing.close()
        limited = Client(
            binary,
            directory / "complexity-limit",
            work,
            config={"max_nodes": 3, "max_edges": 3},
        )
        try:
            too_big = (
                "```mermaid\n"
                "graph TD\n"
                "N1[a]-->N2[b]\n"
                "N2-->N3[c]\n"
                "N3-->N4[d]\n"
                "N4-->N5[e]\n"
                "```"
            )
            rejected_big = limited.present("complexity-limit", too_big)
            assert not rejected_big["enhanced"]
            assert rejected_big["source"] == too_big
            assert not limited.records("mermaid/artifact", rejected_big)
            assert not [
                entry
                for entry in limited.entries()
                if entry.get("type") == "tool_state"
            ]
        finally:
            limited.close()
        disabled_auto = Client(
            binary,
            directory / "automatic-off",
            work,
            config={"automatic": False},
        )
        try:
            assert not disabled_auto.call("ui.list_markdown_presenters")["data"], (
                "automatic=False must not register markdown presenters"
            )
            off_result = disabled_auto.present("automatic-off", source)
            assert not off_result["enhanced"] and off_result["source"] == source
            assert not disabled_auto.records("mermaid/artifact", off_result)
            assert not [
                entry
                for entry in disabled_auto.entries()
                if entry.get("type") == "tool_state"
            ]
        finally:
            disabled_auto.close()
        started_fifo = directory / "started.fifo"
        release_fifo = directory / "release.fifo"
        os.mkfifo(started_fifo)
        os.mkfifo(release_fifo)
        mock_mmdc = directory / "mock-mmdc"
        mock_png = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAYAAAB3AH1ZAAAAJElEQVR4nGOQ23Lp/0BihlEHjDpg1AGjDhh1wKgDRh0w0A4AALXQRkwBCanJAAAAAElFTkSuQmCC"
        )
        mock_mmdc.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "if '--version' in sys.argv:\n"
            "    sys.stdout.write('12.0.0\\n')\n"
            "    sys.exit(0)\n"
            "sys.stdin.buffer.read()\n"
            f"sfd = os.open({str(started_fifo)!r}, os.O_WRONLY)\n"
            "os.write(sfd, f'{os.getpid()}\\n'.encode('ascii'))\n"
            "os.close(sfd)\n"
            f"rfd = os.open({str(release_fifo)!r}, os.O_RDONLY)\n"
            "os.read(rfd, 1)\n"
            "os.close(rfd)\n"
            f"sys.stdout.buffer.write({mock_png!r})\n",
            encoding="utf-8",
        )
        mock_mmdc.chmod(0o755)
        started_fd = os.open(started_fifo, os.O_RDWR)
        release_fd = os.open(release_fifo, os.O_RDWR)
        started_stream = os.fdopen(started_fd, "r", encoding="utf-8", buffering=1)
        try:
            gated = Client(
                binary,
                directory / "fifo-gated",
                work,
                config={"command": str(mock_mmdc), "timeout_ms": 30000},
            )
            try:
                def start_present(doc_id, body):
                    gated.call(
                        "ui.render_markdown",
                        {
                            "session_id": gated.session_id,
                            "document_id": doc_id,
                            "source": body,
                            "viewport": {
                                "width": 80,
                                "height": 30,
                                "supports_images": True,
                                "supports_artifact_images": True,
                            },
                        },
                    )

                shared_src = "```mermaid\ngraph TD\nOCC_A[one]-->OCC_B[two]\n```"
                start_present("occ-a", shared_src)
                start_present("occ-b", shared_src)
                first_pid = started_stream.readline().strip()
                assert first_pid
                gated.call(
                    "ui.cancel_markdown",
                    {"session_id": gated.session_id, "document_id": "occ-a"},
                )
                occ_a = gated.settled("occ-a")
                assert not occ_a["enhanced"] and occ_a["source"] == shared_src
                os.write(release_fd, b"g")
                occ_b = gated.settled("occ-b")
                assert occ_b["enhanced"], occ_b
                assert len(gated.records("mermaid/artifact", occ_b)) == 1

                # Queue capacity backpressure (2 active + 16 waiters = 18) + immediate cancelled-waiter eviction
                start_present("q-1", "```mermaid\ngraph TD\nQ1[1]-->R1\n```")
                start_present("q-2", "```mermaid\ngraph TD\nQ2[2]-->R2\n```")
                assert started_stream.readline().strip()
                assert started_stream.readline().strip()
                for idx in range(3, 19):
                    start_present(
                        f"q-{idx}", f"```mermaid\ngraph TD\nQ{idx}[{idx}]-->R{idx}\n```"
                    )
                snap18 = gated.call(
                    "ui.get_markdown",
                    {"session_id": gated.session_id, "document_id": "q-18"},
                )
                assert snap18 and snap18["pending"] == 1, snap18

                start_present("q-19", "```mermaid\ngraph TD\nQ19[19]-->R19\n```")
                q19 = gated.call(
                    "ui.get_markdown",
                    {"session_id": gated.session_id, "document_id": "q-19"},
                )
                assert q19 and q19["pending"] == 0 and not q19["enhanced"], q19

                # Cancel queued q-3 while q-1 and q-2 remain blocked on release_fd
                gated.call(
                    "ui.cancel_markdown",
                    {"session_id": gated.session_id, "document_id": "q-3"},
                )
                q3 = gated.settled("q-3")
                assert q3["pending"] == 0 and not q3["enhanced"], q3

                start_present("q-20", "```mermaid\ngraph TD\nQ20[20]-->R20\n```")
                q20_queued = gated.call(
                    "ui.get_markdown",
                    {"session_id": gated.session_id, "document_id": "q-20"},
                )
                assert q20_queued and q20_queued["pending"] == 1, q20_queued

                for _ in range(18):
                    os.write(release_fd, b"g")
                # Drain the remaining 16 queued starts (2 already read for q-1, q-2)
                for _ in range(16):
                    assert started_stream.readline().strip()
                q20 = gated.settled("q-20")
                assert q20["enhanced"], q20
                for idx in (1, 2, *range(4, 19)):
                    settled_q = gated.settled(f"q-{idx}")
                    assert settled_q["enhanced"], (idx, settled_q)
            finally:
                gated.close()
        finally:
            started_stream.close()
            os.close(release_fd)
    print(
        "mermaid: actual installed mmdc PNG + native durable tool-state + opaque output + no-image source + syntax failure + cancellation + owner switch + resume + approval + locked read-only + case/info/dedup + missing-mmdc fallback + complexity/dedup/queue-eviction passed"
    )


if __name__ == "__main__":
    main()
