#!/usr/bin/env python3
"""Real TUI resize matrix, CJK wide-char folding, and config parity E2E."""

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = os.environ["MARE_BIN"]

FIXTURE_INIT = """return {
\tname = "terminal-tui-matrix",
\tinject = { "llm" },
\ttags = { "provider" },
\tapply = function(ctx)
\t\tlocal turn, id = 0, nil
\t\tlocal function prior(req, name)
\t\t\tfor i = #req.messages, 1, -1 do
\t\t\t\tlocal m = req.messages[i]
\t\t\t\tif m.role == "tool_result" and m.tool_name == name then
\t\t\t\t\tlocal raw = ""
\t\t\t\t\tfor _, block in ipairs(m.content or {}) do
\t\t\t\t\t\tif block.type == "text" then
\t\t\t\t\t\t\traw = raw .. block.text
\t\t\t\t\t\tend
\t\t\t\t\tend
\t\t\t\t\treturn m, mare.json.decode(raw), raw
\t\t\t\tend
\t\t\tend
\t\tend
\t\tctx.llm:register_provider({
\t\t\tprovider = "terminal-matrix",
\t\t\tdefault_model = "flow",
\t\t\tis_configured = function()
\t\t\t\treturn true
\t\t\tend,
\t\t\tmodels = { { model_id = "flow", name = "Terminal Matrix", context_window = 100000, max_output = 4096 } },
\t\t\tstream = function(req, sink)
\t\t\t\tturn = turn + 1
\t\t\t\tlocal name, args
\t\t\t\tif turn == 1 then
\t\t\t\t\tname, args = "terminal_open", { name = "matrix" }
\t\t\t\telseif turn == 2 then
\t\t\t\t\tlocal _, val = prior(req, "terminal_open")
\t\t\t\t\tid = assert(val.session_id)
\t\t\t\t\tname, args = "terminal_send", {
\t\t\t\t\t\tsession_id = id,
\t\t\t\t\t\ttext = "for i in $(seq 1 25); do printf 'LINE-%02d 中文宽字符 🌊\\\\n' \\"$i\\"; done",
\t\t\t\t\t\twait_ms = 2000,
\t\t\t\t\t}
\t\t\t\telseif turn == 3 then
\t\t\t\t\tname, args = "terminal_close", { session_id = id }
\t\t\t\telse
\t\t\t\t\tlocal report = mare.env("TERMINAL_MATRIX_REPORT")
\t\t\t\t\tif report then
\t\t\t\t\t\tmare.fs.write(report, mare.json.encode({ ok = true }))
\t\t\t\t\tend
\t\t\t\t\tsink({ type = "text_delta", delta = "tui resize matrix complete" })
\t\t\t\t\treturn {
\t\t\t\t\t\trole = "assistant",
\t\t\t\t\t\tcontent = { { type = "text", text = "tui resize matrix complete" } },
\t\t\t\t\t\tstop_reason = "stop",
\t\t\t\t\t}
\t\t\t\tend
\t\t\t\tlocal call_id = "matrix-" .. turn
\t\t\t\tsink({ type = "tool_call_start", tool_call_id = call_id, name = name })
\t\t\t\treturn {
\t\t\t\t\trole = "assistant",
\t\t\t\t\tcontent = { { type = "tool_call", id = call_id, name = name, arguments = args } },
\t\t\t\t\tstop_reason = "tool_use",
\t\t\t\t}
\t\t\tend,
\t\t})
\tend,
}
"""

BG_CHECK_INIT = """return {
\tname = "terminal-bg-check",
\tinject = { "tools" },
\tapply = function(ctx)
\t\tctx:on("app/ready", function()
\t\t\tlocal report = mare.env("TERMINAL_BG_REPORT")
\t\t\tif not report then
\t\t\t\treturn
\t\t\tend
\t\t\tlocal ok, err = pcall(function()
\t\t\t\tlocal send_tool = assert(ctx.tools:get("terminal_send"))
\t\t\t\tif mare.env("TERMINAL_EXPECT_HIDDEN") == "1" then
\t\t\t\t\tassert(
\t\t\t\t\t\tsend_tool.parameters.properties.run_in_background == nil,
\t\t\t\t\t\t"run_in_background schema must be hidden when disabled"
\t\t\t\t\t)
\t\t\t\tend
\t\t\t\tlocal opened = ctx.tools:execute(
\t\t\t\t\t{ id = "bg-1", name = "terminal_open", arguments = { name = "bg-off" } },
\t\t\t\t\t{}
\t\t\t\t)
\t\t\t\tassert(not opened.is_error, opened.content)
\t\t\t\tlocal denied = ctx.tools:execute({
\t\t\t\t\tid = "bg-2",
\t\t\t\t\tname = "terminal_send",
\t\t\t\t\targuments = {
\t\t\t\t\t\tsession_id = opened.details.session_id,
\t\t\t\t\t\ttext = "echo nope",
\t\t\t\t\t\trun_in_background = true,
\t\t\t\t\t},
\t\t\t\t}, {})
\t\t\t\tassert(denied.is_error, "run_in_background=true must be rejected when disabled")
\t\t\t\tlocal closed = ctx.tools:execute({
\t\t\t\t\tid = "bg-3",
\t\t\t\t\tname = "terminal_close",
\t\t\t\t\targuments = { session_id = opened.details.session_id },
\t\t\t\t}, {})
\t\t\t\tassert(not closed.is_error and closed.details.stopped)
\t\t\tend)
\t\t\tmare.fs.write(report, mare.json.encode({ ok = ok, error = not ok and tostring(err) or nil }))
\t\tend)
\tend,
}
"""


def run(args, env, cwd):
    p = subprocess.run(args, check=False, env=env, cwd=cwd, capture_output=True, text=True, timeout=90, encoding="utf-8")
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout


with tempfile.TemporaryDirectory(prefix="mare-terminal-tui-matrix-") as tmp:
    base = Path(tmp)
    package = base / "package"
    (package / "plugins").mkdir(parents=True)
    shutil.copy(ROOT / "mare-plugin.toml", package)
    shutil.copytree(ROOT / "plugins/terminals", package / "plugins/terminals")
    (package / "plugins/terminal-tui-matrix").mkdir()
    (package / "plugins/terminal-tui-matrix/init.lua").write_text(FIXTURE_INIT, encoding="utf-8")
    (package / "plugins/terminal-bg-check").mkdir()
    (package / "plugins/terminal-bg-check/init.lua").write_text(BG_CHECK_INIT, encoding="utf-8")

    for args in (
        ["git", "init", "-q", "-b", "main"],
        ["git", "add", "plugins", "mare-plugin.toml"],
        [
            "git",
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "fixture",
        ],
    ):
        run(args, os.environ.copy(), package)

    # 1. Verify enable_run_in_background = false hides schema and rejects execution
    bg_home = base / "bg-home"
    (bg_home / "config").mkdir(parents=True)
    (bg_home / "config/init.lua").write_text(
        f'mare.setup {{model="faux/echo"}}\n'
        f'mare.plugins.add {{{{"test/terminal",url="{package.as_uri()}"}}}}\n'
        f'mare.plugin("terminals", {{enable_run_in_background=false}})\n',
        encoding="utf-8",
    )
    bg_env = os.environ.copy()
    bg_env["MARE_HOME"] = str(bg_home)
    work = base / "work"
    work.mkdir()
    run([BIN, "plugin", "sync"], bg_env, work)
    bg_report = base / "bg-report.json"
    bg_script = base / "bg-script.json"
    bg_script.write_text('[{"text":"bg check done"}]', encoding="utf-8")
    bg_env["TERMINAL_BG_REPORT"] = str(bg_report)
    bg_env["TERMINAL_EXPECT_HIDDEN"] = "1"
    bg_env["MARE_FAUX_SCRIPT"] = str(bg_script)
    run([BIN, "--yolo", "-p", "--json", "--no-session", "check bg disabled"], bg_env, work)
    assert bg_report.exists() and json.loads(bg_report.read_text(encoding="utf-8"))["ok"], bg_report.read_text(encoding="utf-8")

    # 1b. Verify disabling built-in jobs service also hides run_in_background and rejects execution
    nojobs_home = base / "nojobs-home"
    (nojobs_home / "config").mkdir(parents=True)
    (nojobs_home / "config/init.lua").write_text(
        f'mare.setup {{model="faux/echo"}}\n'
        f'mare.plugin("jobs", {{enabled=false}})\n'
        f'mare.plugins.add {{{{"test/terminal",url="{package.as_uri()}"}}}}\n',
        encoding="utf-8",
    )
    nojobs_env = os.environ.copy()
    nojobs_env["MARE_HOME"] = str(nojobs_home)
    run([BIN, "plugin", "sync"], nojobs_env, work)
    nojobs_report = base / "nojobs-report.json"
    nojobs_env["TERMINAL_BG_REPORT"] = str(nojobs_report)
    nojobs_env["MARE_FAUX_SCRIPT"] = str(bg_script)
    run([BIN, "--yolo", "-p", "--json", "--no-session", "check jobs disabled"], nojobs_env, work)
    assert nojobs_report.exists() and json.loads(nojobs_report.read_text(encoding="utf-8"))["ok"], nojobs_report.read_text(encoding="utf-8")

    if os.name != "nt":
        import fcntl
        import pty
        import select
        import signal
        import struct
        import termios

        # 2. Real TUI resize matrix + CJK wide-char folding
        home = base / "home"
        (home / "config").mkdir(parents=True)
        (home / "config/init.lua").write_text(
            f'mare.setup {{model="terminal-matrix/flow"}}\n'
            f'mare.plugins.add {{{{"test/terminal",url="{package.as_uri()}"}}}}\n',
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["MARE_HOME"] = str(home)
        run([BIN, "plugin", "sync"], env, work)

        report = base / "matrix-report.json"
        env.update(TERMINAL_MATRIX_REPORT=str(report), TERM="xterm-256color", MARE_NO_TERM_PROBE="1")
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(work)
            os.execvpe(BIN, [BIN, "--yolo", "--set", "plugins.onboarding.plugins=false", "Exercise terminal TUI resize matrix"], env)

        sizes = [(40, 180), (24, 60), (35, 120), (30, 80)]
        size_idx = 0
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", *sizes[0], 0, 0))
        capture = bytearray()
        try:
            deadline = time.monotonic() + 45
            next_resize = time.monotonic() + 0.5
            while time.monotonic() < deadline and not report.exists():
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        capture.extend(os.read(master, 65536))
                    except OSError:
                        break
                if time.monotonic() >= next_resize and size_idx + 1 < len(sizes):
                    size_idx += 1
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", *sizes[size_idx], 0, 0))
                    os.kill(pid, signal.SIGWINCH)
                    next_resize = time.monotonic() + 0.4

            # Give TUI a moment to render final state across a final resize
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 90, 0, 0))
            os.kill(pid, signal.SIGWINCH)
            settle = time.monotonic() + 0.5
            while time.monotonic() < settle:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        capture.extend(os.read(master, 65536))
                    except OSError:
                        break

            assert report.exists() and json.loads(report.read_text(encoding="utf-8"))["ok"], capture[-4000:]
            assert b"terminal_send" in capture, capture[-4000:]
            assert "中文宽字符".encode() in capture, capture[-4000:]
            assert b"more lines" in capture, capture[-4000:]

            next_exit_key = time.monotonic() + 0.3
            exit_deadline = time.monotonic() + 10
            while time.monotonic() < exit_deadline:
                if time.monotonic() >= next_exit_key:
                    os.write(master, b"\x04")
                    next_exit_key = time.monotonic() + 0.5
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    assert os.waitstatus_to_exitcode(status) == 0
                    pid = 0
                    break
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        capture.extend(os.read(master, 65536))
                    except OSError:
                        pass
            assert pid == 0, "TUI did not exit after Ctrl+D"
        finally:
            if pid:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(master)

print("terminal TUI resize matrix, CJK folding, and enable_run_in_background=false E2E passed")
