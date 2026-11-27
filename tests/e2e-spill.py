#!/usr/bin/env python3
"""Offline file:// package installation, real tool pipeline, recovery across resume, and PTY TUI."""

import base64
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

if os.name != "nt":
    import fcntl
    import termios

PNG_BYTES = b"\x89PNG\r\n\x1a\nPNGDATA1"
JPEG_BYTES = b"\xff\xd8\xff\xe0JPEGDATA2"
PNG_B64 = base64.b64encode(PNG_BYTES).decode("ascii")
JPEG_B64 = base64.b64encode(JPEG_BYTES).decode("ascii")
INPUT_BOX = "╰".encode()


def strip_ansi(raw: bytes) -> str:
    """Drop ANSI CSI/OSC sequences from raw PTY output."""
    return re.sub(
        rb"\x1b\[[0-9;?<>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)",
        b"",
        raw,
    ).decode("utf-8", "replace")


class PtySession:
    """Event-driven PTY harness using select.select (never time.sleep)."""

    def __init__(self, binary: Path, work: Path, env: dict[str, str], args=None):
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, b"\x24\x00\x78\x00\x00\x00\x00\x00")
        self.answered = False
        self.out = b""

        def ctty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        pty_env = dict(env)
        pty_env["TERM"] = "xterm-256color"
        pty_env.pop("TMUX", None)
        cmd = [str(binary), "-C", str(work), "--set", "plugins.onboarding.plugins=false"] + (args or [])
        self.proc = subprocess.Popen(
            cmd,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            cwd=work,
            env=pty_env,
            preexec_fn=ctty,  # noqa: PLW1509
            close_fds=True,
        )
        os.close(slave)

    def _read_once(self, timeout: float):
        ready, _, _ = select.select([self.master], [], [], timeout)
        if not ready:
            return b""
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            if self.proc.poll() is not None:
                return None
            return b""
        self.out += chunk
        if not self.answered and b"\x1b[6n" in self.out:
            self.answered = True
            os.write(self.master, b"\x1b[3;1R\x1b[?62;22c")
        return chunk

    def pump(self, ceiling: float, until=None, until_exit: bool = False) -> bytes:
        got = b""
        end = time.monotonic() + ceiling
        if until and until(self.out):
            return got
        while time.monotonic() < end:
            chunk = self._read_once(0.05)
            if chunk is None:
                break
            if not chunk:
                if until_exit and self.proc.poll() is not None:
                    break
                continue
            got += chunk
            if until and until(self.out):
                break
        return got

    def _is_raw(self) -> bool:
        try:
            return not (termios.tcgetattr(self.master)[3] & termios.ICANON)
        except termios.error:
            return False

    def settle(self, quiet: float = 0.25, ceiling: float = 10.0) -> None:
        end = time.monotonic() + ceiling
        last = time.monotonic()
        while time.monotonic() < end and (time.monotonic() - last) < quiet:
            chunk = self._read_once(0.05)
            if chunk is None:
                break
            if chunk:
                last = time.monotonic()

    def ready(self, ceiling: float = 30.0) -> None:
        self.pump(ceiling, until=lambda b: INPUT_BOX in b)
        deadline = time.monotonic() + ceiling
        while not self._is_raw() and time.monotonic() < deadline:
            self._read_once(0.05)
        self.settle(0.25)

    def submit(self, text: bytes, until, ceiling: float = 30.0) -> bytes:
        seen_not_ready = strip_ansi(self.out).count("startup is still in progress")
        os.write(self.master, text + b"\r")
        deadline = time.monotonic() + ceiling
        while not until(self.out) and time.monotonic() < deadline:
            self.pump(
                0.4,
                until=lambda b, seen=seen_not_ready: until(b)
                or strip_ansi(b).count("startup is still in progress") > seen,
            )
            cur = strip_ansi(self.out).count("startup is still in progress")
            if not until(self.out) and cur > seen_not_ready:
                seen_not_ready = cur
                self.settle(0.3)
                os.write(self.master, b"\r")
        return self.out

    def send(self, keys: bytes) -> None:
        if self.proc.poll() is None:
            os.write(self.master, keys)

    def quit(self, ceiling: float = 20.0) -> int:
        try:
            if self.proc.poll() is None:
                try:
                    os.write(self.master, b"\x04")
                except OSError:
                    pass
                self.pump(5.0, until_exit=True)
            deadline = time.monotonic() + ceiling
            while self.proc.poll() is None and time.monotonic() < deadline:
                try:
                    os.write(self.master, b"\x03")
                except OSError:
                    pass
                self.pump(0.4, until_exit=True)
            if self.proc.poll() is None:
                self.proc.terminate()
            return self.proc.wait(timeout=ceiling)
        finally:
            try:
                os.close(self.master)
            except OSError:
                pass


repo = Path(__file__).resolve().parents[1]
binary = Path(
    os.environ.get("MARE_BIN", repo.parent / "mare/target/debug/mare")
).resolve()

with tempfile.TemporaryDirectory(prefix="mare-spill-e2e-") as temp:
    root = Path(temp).resolve()
    package = root / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(repo / "mare-plugin.toml", package)
    for name, source in [
        ("tool-spill", repo / "plugins/tool-spill"),
        ("spill-probe", repo / "tests/fixtures/spill-probe"),
    ]:
        shutil.copytree(source, package / "plugins" / name)

    route_probe = package / "plugins/spill-route-probe"
    route_probe.mkdir()
    (route_probe / "mare-plugin.toml").write_text(
        'name = "spill-route-probe"\ndescription = "test"\ncategory = "tools"\n',
        encoding="utf-8",
    )
    (route_probe / "init.lua").write_text(
        f"""return {{
\tname = "spill-route-probe",
\tinject = {{ "tools", "llm" }},
\tapply = function(ctx)
\t\tlocal faux = assert(ctx.llm:provider("faux"))
\t\tctx.llm:register_provider({{
\t\t\tprovider = "measured-faux",
\t\t\troute = "faux-route",
\t\t\tdefault_model = "m1",
\t\t\tis_configured = function() return true end,
\t\t\tmodels = {{ {{ model_id = "m1", context_window = 100000, max_output = 4096 }} }},
\t\t\tstream = function(req, sink)
\t\t\t\tlocal cap = assert(mare.env("SPILL_CAPTURE"))
\t\t\t\tassert(mare.fs.write(cap, mare.json.encode(req.messages)))
\t\t\t\tlocal tok_cap = mare.env("SPILL_TOKEN_CAPTURE")
\t\t\t\tif tok_cap and tok_cap ~= "" then
\t\t\t\t\tlocal tool_tokens = {{}}
\t\t\t\t\tlocal route_desc = {{ provider = "measured-faux", model = "m1", wire_route = "faux-route" }}
\t\t\t\t\tlocal has_measure = ctx.llm.measure ~= nil
\t\t\t\t\tlocal img_toks = (mare.text and type(mare.text.image_tokens) == "number") and mare.text.image_tokens or 1200
\t\t\t\t\tfor _, m in ipairs(req.messages) do
\t\t\t\t\t\tif m.tool_name and m.content then
\t\t\t\t\t\t\tlocal sum = 0
\t\t\t\t\t\t\tif has_measure then
\t\t\t\t\t\t\t\tlocal has_img = false
\t\t\t\t\t\t\t\tfor _, b in ipairs(m.content) do
\t\t\t\t\t\t\t\t\tif b.type == "image" then has_img = true end
\t\t\t\t\t\t\t\tend
\t\t\t\t\t\t\t\tif has_img then
\t\t\t\t\t\t\t\t\tlocal measured, merr = ctx.llm:measure(route_desc, m.content)
\t\t\t\t\t\t\t\t\tsum = assert(measured, merr).tokens
\t\t\t\t\t\t\t\telse
\t\t\t\t\t\t\t\t\tfor _, b in ipairs(m.content) do
\t\t\t\t\t\t\t\t\t\tlocal measured, merr = ctx.llm:measure(route_desc, b.text or "")
\t\t\t\t\t\t\t\t\t\tsum = sum + assert(measured, merr).tokens
\t\t\t\t\t\t\t\t\tend
\t\t\t\t\t\t\t\tend
\t\t\t\t\t\t\telse
\t\t\t\t\t\t\t\tlocal tok_fn = (mare.text and type(mare.text.tokens) == "function") and mare.text.tokens or function(s) return math.ceil(#s / 4) end
\t\t\t\t\t\t\t\tfor _, b in ipairs(m.content) do
\t\t\t\t\t\t\t\t\tif b.type == "image" then
\t\t\t\t\t\t\t\t\t\tsum = sum + img_toks
\t\t\t\t\t\t\t\t\telse
\t\t\t\t\t\t\t\t\t\tsum = sum + tok_fn(b.text or "")
\t\t\t\t\t\t\t\t\tend
\t\t\t\t\t\t\t\tend
\t\t\t\t\t\t\tend
\t\t\t\t\t\t\ttool_tokens[m.tool_name] = sum
\t\t\t\t\t\tend
\t\t\t\t\tend
\t\t\t\t\tassert(mare.fs.write(tok_cap, mare.json.encode(tool_tokens)))
\t\t\t\tend
\t\t\t\treturn faux.stream(req, sink)
\t\t\tend,
\t\t}})
\t\t-- core gap: route measurement (llm:register_measurement / llm:measure) is not in core's
\t\t-- public llm contract on main; record whether this core has it for the driver
\t\t-- only the capability probe is protected: once the methods exist, a register_measurement
\t\t-- error fails the run as usual
\t\tlocal measured_ok = pcall(function()
\t\t\tassert(ctx.llm.measure and ctx.llm.register_measurement)
\t\tend)
\t\tif measured_ok then
\t\t\tctx.llm:register_measurement({{
\t\t\t\tprovider = "measured-faux",
\t\t\t\troute = "faux-route",
\t\t\t\tprice_image = function()
\t\t\t\t\treturn {{ visual_tokens = 25, descriptor_text = "img" }}
\t\t\t\tend,
\t\t\t}})
\t\tend
\t\tlocal cap_file = mare.env("SPILL_MEASURE_CAP")
\t\tif cap_file and cap_file ~= "" then
\t\t\tassert(mare.fs.write(cap_file, measured_ok and "measure=yes" or "measure=no"))
\t\tend
\t\tctx.llm:register_provider({{
\t\t\tprovider = "unmeasured-faux",
\t\t\tdefault_model = "m1",
\t\t\tis_configured = function() return true end,
\t\t\tmodels = {{ {{ model_id = "m1", context_window = 100000, max_output = 4096 }} }},
\t\t\tstream = function(req, sink)
\t\t\t\tassert(mare.fs.write(assert(mare.env("SPILL_CAPTURE")), mare.json.encode(req.messages)))
\t\t\t\treturn faux.stream(req, sink)
\t\t\tend,
\t\t}})
\t\tctx.tools:register("spill_text_token", {{
\t\t\tdescription = "Return 2000 bytes of text.",
\t\t\tparameters = {{ type = "object", properties = {{}}, additionalProperties = false }},
\t\t\tside_effect = "read",
\t\t\tidempotent = true,
\t\t\texecute = function()
\t\t\t\treturn {{ content = "HEAD_TOK:" .. string.rep("a", 2000) .. ":TAIL_TOK" }}
\t\t\tend,
\t\t}})
\t\tctx.tools:register("spill_multimodal", {{
\t\t\tdescription = "Return ordered text and image blocks.",
\t\t\tparameters = {{ type = "object", properties = {{}}, additionalProperties = false }},
\t\t\tside_effect = "read",
\t\t\tidempotent = true,
\t\t\texecute = function()
\t\t\t\treturn {{
\t\t\t\t\tcontent = {{
\t\t\t\t\t\t{{ type = "text", text = "HEAD_MM:" .. string.rep("x", 120) }},
\t\t\t\t\t\t{{ type = "image", data = "{PNG_B64}", mime_type = "image/png" }},
\t\t\t\t\t\t{{ type = "text", text = string.rep("m", 2000) }},
\t\t\t\t\t\t{{ type = "image", data = "{JPEG_B64}", mime_type = "image/jpeg" }},
\t\t\t\t\t\t{{ type = "text", text = "TAIL_MM:" .. string.rep("z", 120) }},
\t\t\t\t\t}},
\t\t\t\t}}
\t\t\tend,
\t\t}})
\t\tctx.tools:register("spill_multimodal_bad_image", {{
\t\t\tdescription = "Return a valid image followed by a corrupt image.",
\t\t\tparameters = {{ type = "object", properties = {{}}, additionalProperties = false }},
\t\t\tside_effect = "read",
\t\t\tidempotent = true,
\t\t\texecute = function()
\t\t\t\treturn {{
\t\t\t\t\tcontent = {{
\t\t\t\t\t\t{{ type = "text", text = "HEAD_BAD:" .. string.rep("x", 80) }},
\t\t\t\t\t\t{{ type = "image", data = "{PNG_B64}", mime_type = "image/png" }},
\t\t\t\t\t\t{{ type = "text", text = string.rep("m", 2000) }},
\t\t\t\t\t\t{{ type = "image", data = "bm90LXBuZw==", mime_type = "image/png" }},
\t\t\t\t\t}},
\t\t\t\t}}
\t\t\tend,
\t\t}})
\t\tctx.tools:register("spill_details_meta", {{
\t\t\tdescription = "Return oversized text with details-carried spill metadata.",
\t\t\tparameters = {{ type = "object", properties = {{}}, additionalProperties = false }},
\t\t\tside_effect = "read",
\t\t\tidempotent = true,
\t\t\texecute = function()
\t\t\t\treturn {{
\t\t\t\t\tcontent = "DETMETA:" .. string.rep("d", 2200),
\t\t\t\t\tdetails = {{
\t\t\t\t\t\tsuggested_name = "detached-meta",
\t\t\t\t\t\tspill_source = {{
\t\t\t\t\t\t\tkind = "session-reference",
\t\t\t\t\t\t\tsession_id = "sess-parent",
\t\t\t\t\t\t\tlabel = "parent-transcript",
\t\t\t\t\t\t}},
\t\t\t\t\t}},
\t\t\t\t}}
\t\t\tend,
\t\t}})
\t\tctx.tools:register("spill_exempt_probe", {{
\t\t\tdescription = "Return oversized text marked spill_exempt via details.",
\t\t\tparameters = {{ type = "object", properties = {{}}, additionalProperties = false }},
\t\t\tside_effect = "read",
\t\t\tidempotent = true,
\t\t\texecute = function()
\t\t\t\treturn {{
\t\t\t\t\tcontent = "EXEMPT_HEAD:" .. string.rep("e", 2200),
\t\t\t\t\tdetails = {{ spill_exempt = true }},
\t\t\t\t}}
\t\t\tend,
\t\t}})
\t\tctx.tools:register("spill_wait_cancel", {{
\t\t\tdescription = "Signal readiness then wait for cancellation token.",
\t\t\tparameters = {{ type = "object", properties = {{}}, additionalProperties = false }},
\t\t\tside_effect = "read",
\t\t\tidempotent = true,
\t\t\texecute = function(_args, info)
\t\t\t\tif info and info.update then
\t\t\t\t\tinfo.update({{ output = "WAIT_CANCEL_STARTED" }})
\t\t\t\tend
\t\t\t\tif info and info.cancel then
\t\t\t\t\tinfo.cancel:wait()
\t\t\t\tend
\t\t\t\treturn {{
\t\t\t\t\tcontent = "CANCELED_SPILL:" .. string.rep("c", 6000),
\t\t\t\t\tcancelled = info and info.cancel and info.cancel:is_cancelled() or nil,
\t\t\t\t}}
\t\t\tend,
\t\t}})
\tend,
}}
""",
        encoding="utf-8",
    )

    def run(*args):
        result = subprocess.run(
            args, check=False, text=True, capture_output=True, env=env,
            encoding="utf-8",
        )
        assert result.returncode == 0, f"{args}: {result.stdout}\n{result.stderr}"
        if result.stderr:
            print(result.stderr)
        return result

    env = os.environ | {
        "MARE_HOME": str(root / "home"),
        "SPILL_CAPTURE": str(root / "capture.json"),
        "SPILL_TOKEN_CAPTURE": str(root / "tokens.json"),
        "SPILL_CANCEL_READY": str(root / "cancel.ready"),
        "MARE_FAUX_SCRIPT": str(root / "script.json"),
        "SPILL_MEASURE_CAP": str(root / "measure.cap"),
    }
    run("git", "-C", str(package), "init", "-q", "-b", "main")
    run("git", "-C", str(package), "add", "-A")
    run(
        "git",
        "-C",
        str(package),
        "-c",
        "user.name=test",
        "-c",
        "user.email=test@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "fixture",
    )
    config = root / "home/config"
    config.mkdir(parents=True)
    (config / "init.lua").write_text(
        f'mare.setup {{ model = "spill-faux/small" }}\nmare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n',
        encoding="utf-8",
    )
    work = root / "work"
    work.mkdir()
    run(str(binary), "-C", str(work), "plugin", "sync")

    print("[e2e] 1. core spill + read/grep interop", flush=True)
    # 1. Core spill, rich retrieval_hint + suggested_name, read_spill, read & bash grep interop
    (root / "script.json").write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "spill_fixture", "arguments": {}}]},
                {"text": "done"},
            ]
        ),
        encoding="utf-8",
    )
    run(
        str(binary),
        "-C",
        str(work),
        "-p",
        "--session-id",
        "spill-e2e",
        "generate fixture",
    )
    messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
    result = next(m for m in messages if m.get("tool_name") == "spill_fixture")
    text = "".join(b["text"] for b in result["content"])
    assert len(text.encode()) <= 4096, (len(text.encode()), text[:300], text[-700:])
    assert "Complete tool output" in text
    assert "Use read_spill with offset/limit, or read (offset/limit) / grep at " in text
    handle = text.split(" bytes): ", 1)[1].split(". Use read_spill", 1)[0]
    full_text = "αβ recovery line\n" * 7000
    saved = next(
        p for p in (root / "home").rglob("*.txt") if p.read_bytes() == full_text.encode()
    )
    assert saved.name.endswith("-spill_fixture.txt")
    assert str(saved) in text and text.endswith(f"{saved}.]")
    assert saved.read_text(encoding="utf-8") == full_text
    assert result["details"]["marker"] == "preserved"
    if os.name != "nt":
        assert saved.stat().st_mode & 0o777 == 0o600

    # A real read_spill, read, and bash grep after resume all read the same recovery file.
    (root / "script.json").write_text(
        json.dumps(
            [
                {
                    "tool_calls": [
                        {
                            "name": "read_spill",
                            "arguments": {"handle": handle, "offset": 2, "limit": 1},
                        },
                        {
                            "name": "read",
                            "arguments": {
                                "path": str(saved),
                                "offset": 2,
                                "limit": 1,
                            },
                        },
                        {
                            "name": "bash",
                            "arguments": {
                                "command": f"grep -n -m 1 'αβ recovery line' {json.dumps(saved.as_posix())}"
                            },
                        },
                    ]
                },
                {"text": "recovered"},
            ]
        ),
        encoding="utf-8",
    )
    recover_args = [str(binary), "-C", str(work), "-p", "--resume", "spill-e2e"]
    if os.name == "nt":
        recover_args.append("--yolo")
    run(*recover_args, "recover")
    messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
    read_spill_res = next(m for m in messages if m.get("tool_name") == "read_spill")
    read_spill_text = "".join(b["text"] for b in read_spill_res["content"])
    assert (
        read_spill_text.startswith("αβ recovery line\n")
        and "Complete tool output" not in read_spill_text
    )
    read_res = next(m for m in messages if m.get("tool_name") == "read")
    read_tool_text = "".join(b["text"] for b in read_res["content"])
    assert "αβ recovery line" in read_tool_text
    bash_res = next(m for m in messages if m.get("tool_name") == "bash")
    bash_tool_text = "".join(b["text"] for b in bash_res["content"])
    assert "1:αβ recovery line" in bash_tool_text
    assert saved.exists()

    # Persisted text carries its locator across a second result and a smaller
    # preview, without a second save. A notice-only result follows the same path.
    notice = text[text.rindex("[Complete tool output") :]
    for replay in ("replayed line\n" * 5000 + notice, notice):
        before = set(saved.parent.glob("*.txt"))
        (root / "script.json").write_text(
            json.dumps(
                [
                    {
                        "tool_calls": [
                            {"name": "spill_fixture", "arguments": {"replay": replay}}
                        ]
                    },
                    {"text": "replayed"},
                ]
            ),
            encoding="utf-8",
        )
        run(str(binary), "-C", str(work), "-p", "--resume", "spill-e2e", "replay")
        replay_messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        replay_result = [
            m for m in replay_messages if m.get("tool_name") == "spill_fixture"
        ][-1]
        replay_text = "".join(b["text"] for b in replay_result["content"])
        assert replay_text.endswith(notice) and len(replay_text.encode()) <= 4096
        assert replay_text.count("[Complete tool output") == 1
        assert set(saved.parent.glob("*.txt")) == before

    print("[e2e] 2. deny_read", flush=True)
    # 2. deny_read denies read_spill & read AND triggers in-memory budget fallback on spill
    env["SPILL_DENY"] = "1"
    (root / "script.json").write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "spill_fixture", "arguments": {}}]},
                {"text": "denied storage"},
            ]
        ),
        encoding="utf-8",
    )
    run(
        str(binary),
        "-C",
        str(work),
        "-p",
        "--session-id",
        "spill-denied",
        "generate fixture",
    )
    denied_messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
    denied_result = next(
        m for m in denied_messages if m.get("tool_name") == "spill_fixture"
    )
    denied_text = "".join(b["text"] for b in denied_result["content"])
    assert "Complete tool output" not in denied_text
    assert denied_text.startswith("αβ recovery line")
    assert "could not be saved" in denied_text
    assert len(denied_text.encode()) <= 4300, len(denied_text.encode())
    (root / "script.json").write_text(
        json.dumps(
            [
                {
                    "tool_calls": [
                        {
                            "name": "read_spill",
                            "arguments": {"handle": handle, "offset": 1, "limit": 1},
                        },
                        {
                            "name": "read",
                            "arguments": {"path": str(saved), "offset": 1, "limit": 1},
                        },
                    ]
                },
                {"text": "denied reads"},
            ]
        ),
        encoding="utf-8",
    )
    run(str(binary), "-C", str(work), "-p", "--resume", "spill-e2e", "denied reads")
    denied_read_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
    for tool_name in ("read_spill", "read"):
        msg = [m for m in denied_read_msgs if m.get("tool_name") == tool_name][-1]
        assert msg.get("is_error") or "denied" in "".join(
            b["text"] for b in msg["content"]
        ).lower()
    del env["SPILL_DENY"]

    print("[e2e] 3. rpc", flush=True)
    # 3. RPC omits host path while keeping handle & spill.* methods functional
    process = subprocess.Popen(
        [str(binary), "-C", str(work), "--rpc", "--resume", "spill-e2e"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        encoding="utf-8",
    )

    def rpc(method, params):
        global_counter = rpc.counter
        rpc.counter += 1
        process.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": global_counter,
                    "method": method,
                    "params": params,
                }
            )
            + "\n"
        )
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            assert line, process.stderr.read()
            message = json.loads(line)
            if message.get("id") == global_counter:
                return message

    rpc.counter = 1
    try:
        init_rpc = rpc("initialize", {"protocol_version": "3.0"})["result"]
        assert all(
            method in init_rpc["capabilities"]["methods"]
            for method in (
                "spill.list_backends",
                "spill.save",
                "spill.read",
                "spill.delete",
            )
        )
        backends = rpc("spill.list_backends", {})["result"]["data"]
        assert isinstance(backends, list) and any(
            b.get("name") == "local" for b in backends
        )
        stored_bytes = rpc(
            "spill.save", {"session_id": "spill-e2e", "data_base64": "aGVsbG8gd29ybGQ="}
        )["result"]
        assert "path" not in stored_bytes and stored_bytes["size"] == 11
        assert (
            rpc(
                "spill.delete",
                {"session_id": "spill-e2e", "spill_id": stored_bytes["spill_id"]},
            )["result"]
            == {}
        )
        stored = rpc("spill.save", {"session_id": "spill-e2e", "content": "界" * 40000})[
            "result"
        ]
        assert "path" not in stored and stored["size"] == 120000
        recovered = ""
        offset = 0
        while True:
            page = rpc(
                "spill.read",
                {
                    "session_id": "spill-e2e",
                    "spill_id": stored["spill_id"],
                    "offset": offset,
                },
            )["result"]
            recovered += page["content"]
            assert len(page["content"].encode()) <= 51200
            if "next_offset" not in page:
                break
            assert page["next_offset"] > offset
            offset = page["next_offset"]
        assert recovered == "界" * 40000
        other_session = rpc("session.create", {})["result"]["session_id"]
        assert "error" in rpc(
            "spill.read", {"session_id": other_session, "spill_id": stored["spill_id"]}
        )
        assert "result" in rpc("session.load", {"session_id": "spill-e2e"})
        assert (
            rpc(
                "spill.delete",
                {"session_id": "spill-e2e", "spill_id": stored["spill_id"]},
            )["result"]
            == {}
        )
        assert "error" in rpc(
            "spill.read", {"session_id": "spill-e2e", "spill_id": stored["spill_id"]}
        )
        assert (
            rpc(
                "spill.read",
                {"session_id": "spill-e2e", "spill_id": "bad", "path": str(saved)},
            )["error"]["code"]
            == -32602
        )
        rpc("shutdown", {})
        process.wait(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    # 4. Configured spill.root + deferred startup cleanup sweep
    init = config / "init.lua"
    init.write_text(
        f'mare.setup {{ model = "spill-faux/small" }}\n'
        f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
        'mare.plugin("tool-spill", {root="recover-custom", cleanup_period_days=90})\n',
        encoding="utf-8",
    )
    (root / "script.json").write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "spill_fixture", "arguments": {}}]},
                {"text": "custom saved"},
            ]
        ),
        encoding="utf-8",
    )
    run(str(binary), "-C", str(work), "-p", "--session-id", "spill-custom", "save")
    custom_messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
    custom_result = next(
        m for m in custom_messages if m.get("tool_name") == "spill_fixture"
    )
    custom_text = "".join(b["text"] for b in custom_result["content"])
    custom_handle = custom_text.split(" bytes): ", 1)[1].split(". Use read_spill", 1)[0]
    custom_file = next((work / "recover-custom").rglob("*.txt"))
    assert custom_file.read_text(encoding="utf-8") == full_text
    expired = time.time() - 40 * 86400
    os.utime(custom_file, (expired, expired))
    (root / "script.json").write_text(
        json.dumps(
            [
                {
                    "tool_calls": [
                        {"name": "read_spill", "arguments": {"handle": custom_handle}}
                    ]
                },
                {"text": "custom recovered"},
            ]
        ),
        encoding="utf-8",
    )
    run(str(binary), "-C", str(work), "-p", "--resume", "spill-custom", "recover")
    assert custom_file.exists()
    with init.open("a") as stream:
        stream.write('mare.plugin("tool-spill", {cleanup_period_days=30})\n')
    (root / "script.json").write_text(json.dumps([{"text": "startup sweep"}]), encoding="utf-8")
    run(str(binary), "-C", str(work), "-p", "--resume", "spill-custom", "sweep")
    assert not custom_file.exists() and custom_file.parent.exists()

    print("[e2e] 5. storage failure", flush=True)
    # 5. A storage failure (here: a spill root the process cannot write) keeps cfg.max_bytes strictly
    # in-memory. Spill stores through core mare.spill since f84156f, so the failure is a real one
    # from the local store, not a registered fake backend.
    failing_root = root / "unwritable-spill"
    if os.name == "nt":
        # POSIX chmod(0o500) does not block directory creation on Windows; use a regular file
        # at the configured root so the local spill store hits a real filesystem error.
        failing_root.write_text("not a directory", encoding="utf-8")
    else:
        failing_root.mkdir()
        failing_root.chmod(0o500)
    init.write_text(
        f'mare.setup {{ model = "spill-faux/small" }}\n'
        f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
        f'mare.plugin("tool-spill", {{ root = {json.dumps(str(failing_root))}, max_bytes = 600, max_lines = 12 }})\n',
        encoding="utf-8",
    )
    (root / "script.json").write_text(
        json.dumps(
            [
                {"tool_calls": [{"name": "spill_fixture", "arguments": {}}]},
                {"text": "enospc handled"},
            ]
        ),
        encoding="utf-8",
    )
    run(str(binary), "-C", str(work), "-p", "--session-id", "spill-enospc", "enospc")
    enospc_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
    enospc_res = next(m for m in enospc_msgs if m.get("tool_name") == "spill_fixture")
    enospc_text = "".join(b["text"] for b in enospc_res["content"])
    if os.name != "nt":
        failing_root.chmod(0o700)
    assert len(enospc_text.encode()) <= 600, len(enospc_text.encode())
    assert "could not be saved" in enospc_text, enospc_text
    assert "Complete tool output" not in enospc_text

    # sections 6-7 assert fallback token/image estimation (mare.text.tokens, or route measurement if present)
    measure_cap=(root / "measure.cap").read_text(encoding="utf-8").strip()
    assert measure_cap in ("measure=yes","measure=no"),measure_cap
    if True:
        print("[e2e] 6. N10 multimodal", flush=True)
        # 6. N10: Route-measured max_inline_tokens, decoded binary image bytes + MIME + order + bad-image cleanup
        tok_mm = 220
        mm_root = root / "mm-spill"
        init.write_text(
            f'mare.setup {{ model = "measured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(mm_root))}, max_inline_tokens = {tok_mm} }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {
                        "tool_calls": [
                            {"name": "spill_text_token", "arguments": {}},
                            {"name": "spill_multimodal", "arguments": {}},
                        ]
                    },
                    {"text": "measured done"},
                ]
            ),
            encoding="utf-8",
        )
        run(
            str(binary),
            "-C",
            str(work),
            "-p",
            "--session-id",
            "spill-tokens",
            "run measured tools",
        )
        tok_messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        tok_res = next(
            m for m in tok_messages if m.get("tool_name") == "spill_text_token"
        )
        tok_text = "".join(b["text"] for b in tok_res["content"])
        assert "Complete tool output" in tok_text and "omitted" in tok_text
        assert len(tok_text) < 2000

        mm_res = next(m for m in tok_messages if m.get("tool_name") == "spill_multimodal")
        mm_texts = [b["text"] for b in mm_res["content"] if b.get("type") == "text"]
        assert any("Complete tool output" in t for t in mm_texts), (
            mm_res,
            [p.read_text(errors="replace", encoding="utf-8")[-1000:] for p in (root / "home").rglob("*.log")],
        )
        assert any("omitted" in t for t in mm_texts), mm_res
        mm_notice = next(t for t in mm_texts if "Complete tool output" in t)
        mm_handle = mm_notice.split(" bytes): ", 1)[1].split(". Use read_spill", 1)[0]
        (root / "script.json").write_text(
            json.dumps(
                [
                    {
                        "tool_calls": [
                            {"name": "read_spill", "arguments": {"handle": mm_handle}}
                        ]
                    },
                    {"text": "mm transcript"},
                ]
            ),
            encoding="utf-8",
        )
        run(
            str(binary),
            "-C",
            str(work),
            "-p",
            "--resume",
            "spill-tokens",
            "read mm transcript",
        )
        mm_t_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        mm_t_res = [m for m in mm_t_msgs if m.get("tool_name") == "read_spill"][-1]
        mm_transcript = "".join(b["text"] for b in mm_t_res["content"])
        idx1 = mm_transcript.index("[Image #1: mime=image/png")
        idx2 = mm_transcript.index("[Image #2: mime=image/jpeg")
        assert idx1 < idx2
        m_paths = re.findall(r"path=([^,\]]+)", mm_transcript)
        assert len(m_paths) == 2
        assert Path(m_paths[0]).read_bytes() == PNG_BYTES
        assert Path(m_paths[1]).read_bytes() == JPEG_BYTES

        # details.suggested_name / details.spill_source survive detach() and details.spill_exempt skips spilling
        before_meta = set(mm_root.rglob("*.txt"))
        (root / "script.json").write_text(
            json.dumps(
                [
                    {
                        "tool_calls": [
                            {"name": "spill_details_meta", "arguments": {}},
                            {"name": "spill_exempt_probe", "arguments": {}},
                        ]
                    },
                    {"text": "meta and exempt checked"},
                ]
            ),
            encoding="utf-8",
        )
        run(
            str(binary),
            "-C",
            str(work),
            "-p",
            "--resume",
            "spill-tokens",
            "meta and exempt",
        )
        meta_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        meta_res = [m for m in meta_msgs if m.get("tool_name") == "spill_details_meta"][-1]
        meta_text = "".join(b["text"] for b in meta_res["content"])
        assert "Complete tool output" in meta_text
        new_meta_files = sorted(set(mm_root.rglob("*.txt")) - before_meta)
        assert len(new_meta_files) == 1, new_meta_files
        assert new_meta_files[0].name.endswith("-detached-meta.txt")
        assert meta_res["details"]["spill"]["suggested_name"] == "detached-meta.txt"
        assert meta_res["details"]["spill"]["source"]["kind"] == "session-reference"

        exempt_res = [
            m for m in meta_msgs if m.get("tool_name") == "spill_exempt_probe"
        ][-1]
        exempt_text = "".join(b["text"] for b in exempt_res["content"])
        assert exempt_text.startswith("EXEMPT_HEAD:")
        assert "Complete tool output" not in exempt_text

        # Corrupt second image must clean up first image handle cleanly and leave zero new files
        before_bad = set(mm_root.rglob("*.txt"))
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_multimodal_bad_image", "arguments": {}}]},
                    {"text": "bad image handled"},
                ]
            ),
            encoding="utf-8",
        )
        run(
            str(binary),
            "-C",
            str(work),
            "-p",
            "--resume",
            "spill-tokens",
            "bad image",
        )
        bad_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        bad_res = [m for m in bad_msgs if m.get("tool_name") == "spill_multimodal_bad_image"][-1]
        bad_text = "".join(b["text"] for b in bad_res["content"] if b.get("type") == "text")
        assert "could not be saved" in bad_text and "Complete tool output" not in bad_text
        assert set(mm_root.rglob("*.txt")) == before_bad

        print("[e2e] 7. N11 tight token budget", flush=True)
        # 7. N11: Strict token budget enforcement (explicit failure at tok_fail, compact fallback at tok_compact, unexpressible 10, critical T_tight)
        tok_fail = 72 if measure_cap == "measure=yes" else 20
        n11_root = root / "s"
        before_72 = set(n11_root.rglob("*.txt")) if n11_root.exists() else set()
        init.write_text(
            f'mare.setup {{ model = "measured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(n11_root))}, max_inline_tokens = {tok_fail} }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {
                        "tool_calls": [
                            {"name": "spill_text_token", "arguments": {}},
                            {"name": "spill_multimodal", "arguments": {}},
                        ]
                    },
                    {"text": "72 strict budget failure"},
                ]
            ),
            encoding="utf-8",
        )
        run(str(binary), "-C", str(work), "-p", "--session-id", "spill-72", "tight 72")
        tokens_captured = json.loads((root / "tokens.json").read_text(encoding="utf-8"))
        assert tokens_captured["spill_text_token"] <= tok_fail, (
            tokens_captured["spill_text_token"],
            tok_fail,
        )
        assert tokens_captured["spill_multimodal"] <= tok_fail, (
            tokens_captured["spill_multimodal"],
            tok_fail,
        )
        m72_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        m72_res = next(m for m in m72_msgs if m.get("tool_name") == "spill_text_token")
        m72_mm_res = next(m for m in m72_msgs if m.get("tool_name") == "spill_multimodal")
        m72_text = "".join(b["text"] for b in m72_res["content"])
        m72_mm_text = "".join(b["text"] for b in m72_mm_res["content"])
        assert m72_res.get("is_error") and "output exceeds inline token budget" in m72_text
        assert m72_mm_res.get("is_error") and "output exceeds inline token budget" in m72_mm_text
        assert "Complete tool output" not in m72_text
        after_72 = set(n11_root.rglob("*.txt")) if n11_root.exists() else set()
        assert after_72 == before_72, f"notice exceeding budget={tok_fail} must revoke all saved handles"

        # Budget=90 (or 48 under fallback-tokens): rich path hint (> budget) falls back to compact read_spill notice (<= budget)
        tok_compact = 90 if measure_cap == "measure=yes" else 48
        n90_root = root / "s90"
        init.write_text(
            f'mare.setup {{ model = "measured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(n90_root))}, max_inline_tokens = {tok_compact} }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_text_token", "arguments": {}}]},
                    {"text": "90 compact recovery"},
                ]
            ),
            encoding="utf-8",
        )
        run(str(binary), "-C", str(work), "-p", "--session-id", "spill-90", "compact 90")
        tokens_90 = json.loads((root / "tokens.json").read_text(encoding="utf-8"))
        assert tokens_90["spill_text_token"] <= tok_compact, tokens_90["spill_text_token"]
        m90_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        m90_res = next(m for m in m90_msgs if m.get("tool_name") == "spill_text_token")
        m90_text = "".join(b["text"] for b in m90_res["content"])
        assert "Complete tool output" in m90_text and "Use read_spill with offset/limit." in m90_text

        # Unexpressible config max_inline_tokens=10 fails loudly instead of silently passing raw payloads
        init.write_text(
            f'mare.setup {{ model = "measured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(n90_root))}, max_inline_tokens = 10 }})\n',
            encoding="utf-8",
        )
        bad_cfg = subprocess.run(
            [str(binary), "-C", str(work), "-p", "--session-id", "spill-10", "bad cfg"],
            check=False,
            text=True,
            capture_output=True,
            env=env,
            encoding="utf-8",
        )
        assert bad_cfg.returncode != 0 or "max_inline_tokens" in (bad_cfg.stdout + bad_cfg.stderr)
        # Run once with high budget to inspect exact notice length, then run at T_tight = notice_tokens + 4
        tok_probe = 300
        init.write_text(
            f'mare.setup {{ model = "measured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(n11_root))}, max_inline_tokens = {tok_probe} }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_text_token", "arguments": {}}]},
                    {"text": "probe notice size"},
                ]
            ),
            encoding="utf-8",
        )
        run(str(binary), "-C", str(work), "-p", "--session-id", "spill-probe-size", "probe")
        probe_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        probe_txt = "".join(
            b["text"]
            for b in next(
                m for m in probe_msgs if m.get("tool_name") == "spill_text_token"
            )["content"]
        )
        probe_notice = probe_txt[probe_txt.rindex("[Complete tool output") :]
        t_tight = (len(probe_notice.encode()) + 3) // 4 + 4
        init.write_text(
            f'mare.setup {{ model = "measured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(n11_root))}, max_inline_tokens = {t_tight} }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {
                        "tool_calls": [
                            {"name": "spill_text_token", "arguments": {}},
                            {"name": "spill_multimodal", "arguments": {}},
                        ]
                    },
                    {"text": "critical tight done"},
                ]
            ),
            encoding="utf-8",
        )
        run(str(binary), "-C", str(work), "-p", "--session-id", "spill-tight", "tight")
        tight_tokens = json.loads((root / "tokens.json").read_text(encoding="utf-8"))
        assert tight_tokens["spill_text_token"] <= t_tight, (
            tight_tokens["spill_text_token"],
            t_tight,
        )
        assert tight_tokens["spill_multimodal"] <= t_tight, (
            tight_tokens["spill_multimodal"],
            t_tight,
        )
        tight_msgs = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        tight_text = "".join(
            b["text"]
            for b in next(
                m for m in tight_msgs if m.get("tool_name") == "spill_text_token"
            )["content"]
        )
        assert "Complete tool output" in tight_text
        tight_mm = next(m for m in tight_msgs if m.get("tool_name") == "spill_multimodal")
        tight_mm_texts = [b["text"] for b in tight_mm["content"] if b.get("type") == "text"]
        assert len(tight_mm["content"]) == 1 and "Complete tool output" in tight_mm_texts[0]

    # 8. Unmeasured route must fail closed (keep original output without spilling). Like 6-7 this
    # needs core route measurement: without llm:measure every route uses the fallback token estimate
    # (mare.text.tokens) and the strict budget instead, so the section runs only when the probe recorded measure=yes.
    if measure_cap == "measure=yes":
        init.write_text(
            f'mare.setup {{ model = "unmeasured-faux/m1" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ max_inline_tokens = 180 }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_text_token", "arguments": {}}]},
                    {"text": "unmeasured done"},
                ]
            ),
            encoding="utf-8",
        )
        run(
            str(binary),
            "-C",
            str(work),
            "-p",
            "--session-id",
            "spill-unmeasured",
            "run unmeasured",
        )
        unm_messages = json.loads((root / "capture.json").read_text(encoding="utf-8"))
        unm_res = next(
            m for m in unm_messages if m.get("tool_name") == "spill_text_token"
        )
        unm_text = "".join(b["text"] for b in unm_res["content"])
        assert "Complete tool output" not in unm_text
        assert unm_text.startswith("HEAD_TOK:"), unm_text[:600]

    if os.name != "nt":
        print("[e2e] 9. PTY TUI", flush=True)
        # 9. Real TUI/PTY tests: spill notice + Ctrl+O expansion + Esc close, Esc cancel, and error paths
        tui_spill_root = root / "tui-spill"
        init.write_text(
            f'mare.setup {{ model = "spill-faux/small" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(tui_spill_root))}, max_lines = 8 }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_fixture", "arguments": {}}]},
                    {"text": "TUI_SPILL_DONE"},
                    {
                        "tool_calls": [
                            {
                                "name": "read_spill",
                                "arguments": {"handle": "invalid-handle"},
                            }
                        ]
                    },
                    {"text": "TUI_BAD_READ_DONE"},
                ]
            ),
            encoding="utf-8",
        )
        pty = PtySession(binary, work, env)
        try:
            pty.ready()
            pty.submit(
                b"run tui spill",
                until=lambda b: b"TUI_SPILL_DONE" in b and INPUT_BOX in b[b.rfind(b"TUI_SPILL_DONE") :],
            )
            pty.settle(0.25)
            # Ctrl+O expands the committed tool call via transcript/detail view
            pty.send(b"\x0f")
            pty.pump(
                15.0,
                until=lambda b: b"Complete tool output" in b and b"read_spill" in b and b".txt" in b,
            )
            pty.settle(0.25)
            expanded_plain = strip_ansi(pty.out)
            assert "Complete tool output" in expanded_plain, expanded_plain[-3000:]
            assert "read_spill" in expanded_plain, expanded_plain[-3000:]
            assert "-spill_fixture.txt" in re.sub(r"\s+", "", expanded_plain), expanded_plain[-3000:]
            # Esc closes expanded overlay cleanly
            pty.send(b"\x1b")
            pty.settle(0.25)

            # Invalid read_spill handle renders error cleanly in TUI
            pty.submit(
                b"bad read_spill",
                until=lambda b: b"TUI_BAD_READ_DONE" in b and INPUT_BOX in b[b.rfind(b"TUI_BAD_READ_DONE") :],
            )
            pty.settle(0.25)
            pty.send(b"\x0f")
            pty.pump(15.0, until=lambda b: b"invalid spill_id" in b)
            bad_plain = strip_ansi(pty.out)
            assert "invalid spill_id" in bad_plain, bad_plain[-3000:]
            pty.send(b"\x1b")
            pty.settle(0.25)
        finally:
            assert pty.quit() == 0

        # TUI Cancel (Esc while spill_wait_cancel is running) -> Interrupted, no spill file created
        before_cancel = set(tui_spill_root.rglob("*.txt"))
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_wait_cancel", "arguments": {}}]},
                    {"text": "SHOULD_NOT_COMPLETE"},
                ]
            ),
            encoding="utf-8",
        )
        pty_cancel = PtySession(binary, work, env)
        try:
            pty_cancel.ready()
            pty_cancel.submit(
                b"wait cancel",
                until=lambda b: b"spill_wait_cancel" in b,
                ceiling=20.0,
            )
            assert b"spill_wait_cancel" in pty_cancel.out, strip_ansi(pty_cancel.out)[-1000:]
            cancel_mark = len(pty_cancel.out)
            pty_cancel.send(b"\x1b")
            pty_cancel.pump(
                15.0,
                until=lambda b: b"Ask mare anything" in b[cancel_mark:],
            )
            pty_cancel.settle(0.25)
            cancel_plain = strip_ansi(pty_cancel.out)
            assert "SHOULD_NOT_COMPLETE" not in cancel_plain
            assert "Interrupt" in cancel_plain or "interrupt" in cancel_plain or "cancel" in cancel_plain.lower() or "aborted" in cancel_plain.lower(), cancel_plain[-2000:]
            assert set(tui_spill_root.rglob("*.txt")) == before_cancel
        finally:
            assert pty_cancel.quit() == 0

        # TUI Error path: storage failure fallback notice in TUI without fake recovery notice (a spill
        # root the process cannot write, as in section 5)
        failing_root.chmod(0o500)
        init.write_text(
            f'mare.setup {{ model = "spill-faux/small" }}\n'
            f'mare.plugins.add {{ {{ "test/spill", url = "{package.as_uri()}" }} }}\n'
            f'mare.plugin("tool-spill", {{ root = {json.dumps(str(failing_root))}, max_bytes = 600, max_lines = 8 }})\n',
            encoding="utf-8",
        )
        (root / "script.json").write_text(
            json.dumps(
                [
                    {"tool_calls": [{"name": "spill_fixture", "arguments": {}}]},
                    {"text": "TUI_ENOSPC_DONE"},
                ]
            ),
            encoding="utf-8",
        )
        pty_err = PtySession(binary, work, env)
        try:
            pty_err.ready()
            pty_err.submit(
                b"enospc tui",
                until=lambda b: b"TUI_ENOSPC_DONE" in b and INPUT_BOX in b[b.rfind(b"TUI_ENOSPC_DONE") :],
            )
            pty_err.settle(0.25)
            pty_err.send(b"\x0f")
            pty_err.pump(15.0, until=lambda b: b"could not be saved" in b)
            deny_plain = strip_ansi(pty_err.out)
            assert "could not be saved" in deny_plain
            assert "Complete tool output" not in deny_plain
            pty_err.send(b"\x1b")
            pty_err.settle(0.25)
        finally:
            failing_root.chmod(0o700)
            assert pty_err.quit() == 0

    print(
        "spill file:// faux e2e: recovery, rich metadata, read/grep interop, ENOSPC, N10 binary images, N11 tight budgets, RPC, cleanup, and PTY TUI passed"
    )
