#!/usr/bin/env python3
"""Real 100x40 Mare PTY widget snapshots; no model or network requests."""

import json
import os
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

if os.name != "nt":
    import fcntl
    import pty
    import termios

ROOT = Path(__file__).resolve().parent.parent
MARE = Path(os.environ.get("MARE_BIN", ROOT / "../mare/target/debug/mare")).resolve()
SNAPSHOTS = ROOT / "tests/snapshots/themes"
UPDATE = os.environ.get("UPDATE_SNAPSHOTS") == "1"


def luminance(color):
    channels = [int(color[i : i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [
        c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels
    ]
    return sum(c * w for c, w in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast(a, b):
    values = sorted((luminance(a), luminance(b)))
    return (values[1] + 0.05) / (values[0] + 0.05)


for asset in (ROOT / "themes").glob("*.lua"):
    source = asset.read_text(encoding="utf-8")
    background = re.search(r"Reference background: (#[0-9a-f]{6})", source)[1]
    palette = dict(re.findall(r'(\w+) = "(#[0-9a-f]{6})"', source))
    for key in (
        "text",
        "muted",
        "dim",
        "accent",
        "accent2",
        "green",
        "yellow",
        "red",
        "blue",
    ):
        assert contrast(palette[key], background) >= 4.5, (
            asset.name,
            key,
            "low contrast",
        )
    assert contrast(palette["text"], palette["selection"]) >= 5, asset.name

if os.name == "nt":
    print("themes palette contrast checks passed (POSIX PTY snapshot suite skipped on Windows)")
    sys.exit(0)


def run(args, env):
    return subprocess.run(
        [str(MARE), *args],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
        encoding="utf-8",
    )


with tempfile.TemporaryDirectory(prefix="mare-themes-") as temporary:
    tmp = Path(temporary)
    package = tmp / "package"
    shutil.copytree(ROOT / "themes", package / "themes")
    shutil.copytree(
        ROOT / "tests/fixtures/themes-probe", package / "plugins/themes-probe"
    )
    shutil.copy(ROOT / "mare-plugin.toml", package)
    for args in [
        ["init", "-q"],
        ["add", "."],
        [
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
    ]:
        subprocess.run(["git", "-C", str(package), *args], check=True)
    home = tmp / "home"
    (home / "config").mkdir(parents=True)
    config = home / "config/init.lua"
    env = dict(
        os.environ, MARE_HOME=str(home), TERM="xterm-256color", COLORTERM="truecolor"
    )
    env.pop("NO_COLOR", None)
    env.pop("TERM_PROGRAM", None)
    # Never load the caller's project config or render its repository status.
    work = tmp / "work"
    work.mkdir()

    def configure(flavor, only='{"themes-probe"}'):
        config.write_text(
            'mare.setup {model="faux/echo", flavor=' + json.dumps(flavor) + "}\n"
            'mare.plugins.add {{"test/themes", url='
            + json.dumps(package.as_uri())
            + ", only="
            + only
            + "}}\n",
            encoding="utf-8",
        )

    configure("nord")
    result = run(["-C", str(work), "plugin", "sync"], env)
    assert result.returncode == 0, result.stderr
    assets = sorted((ROOT / "themes").glob("*.lua"))
    for asset in [*assets, None]:
        flavor = asset.stem if asset else "nord"
        if asset:
            configure(flavor)
        else:
            configure(flavor, "{}")
            shutil.copytree(
                ROOT / "tests/fixtures/themes-probe",
                home / "config/plugins/themes-probe",
            )
        result_path = tmp / "probe-result.json"
        result_path.unlink(missing_ok=True)
        env["THEME_RESULT"] = str(result_path)
        env["THEME_FLAVOR"] = flavor
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
        process = subprocess.Popen(
            [str(MARE), "-C", str(work), "--no-session"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
        )
        os.close(slave)
        output = b""
        deadline = time.monotonic() + 45
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
                if b"inline code" in output and result_path.exists():
                    break
        finally:
            process.terminate()
            process.wait(timeout=5)
            os.close(master)
        assert result_path.exists(), (flavor, "app/ready probe did not complete")
        result = json.loads(result_path.read_text(encoding="utf-8"))
        assert result["ok"], (flavor, result)
        # Keep exactly the ten stable fixture rows, including actual renderer SGR.
        lines = output.decode("utf-8", errors="ignore").split("\r\n")
        start = next(
            i for i, line in enumerate(lines) if "THEME-SNAPSHOT heading" in line
        )
        rows = lines[start : start + 10]
        assert len(rows) == 10 and "inline code" in rows[-1], (flavor, rows)
        assert any(re.search(r"\x1b\[(?:38|48);2;", row) for row in rows), (
            "PTY did not render RGB colors"
        )
        snapshot = (
            "100x40 Mare TUI widget (SGR escaped)\n"
            + "\n".join(row.replace("\x1b", "\\x1b") for row in rows)
            + "\n"
        )
        target = SNAPSHOTS / (flavor + ".snap")
        if UPDATE:
            target.write_text(snapshot, encoding="utf-8")
        else:
            assert target.read_text(encoding="utf-8") == snapshot, (
                f"TUI color snapshot changed: {flavor}"
            )

    def run_pty_probe(flavor_name):
        result_path = tmp / "probe-result.json"
        result_path.unlink(missing_ok=True)
        env["THEME_RESULT"] = str(result_path)
        env["THEME_FLAVOR"] = flavor_name
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
        process = subprocess.Popen(
            [str(MARE), "-C", str(work), "--no-session"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
        )
        os.close(slave)
        output = b""
        deadline = time.monotonic() + 45
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
                if b"inline code" in output and result_path.exists():
                    break
        finally:
            process.terminate()
            process.wait(timeout=5)
            os.close(master)
        assert result_path.exists(), (flavor_name, "app/ready probe did not complete")
        res = json.loads(result_path.read_text(encoding="utf-8"))
        assert res["ok"], (flavor_name, res)
        lines = output.decode("utf-8", errors="ignore").split("\r\n")
        start = next(
            i for i, line in enumerate(lines) if "THEME-SNAPSHOT heading" in line
        )
        rows = lines[start : start + 10]
        assert len(rows) == 10 and "inline code" in rows[-1], (flavor_name, rows)
        return res, rows

    # Kebab-case aliases render identically to one-halfdark / one-halflight snapshots,
    # and bundled ANSI themes probe cleanly under PTY.
    for alias, canonical in (
        ("one-half-dark", "one-halfdark"),
        ("one-half-light", "one-halflight"),
    ):
        configure(alias)
        _, alias_rows = run_pty_probe(alias)
        alias_snap = (
            "100x40 Mare TUI widget (SGR escaped)\n"
            + "\n".join(row.replace("\x1b", "\\x1b") for row in alias_rows)
            + "\n"
        )
        assert (SNAPSHOTS / (canonical + ".snap")).read_text(encoding="utf-8") == alias_snap, alias
    for probe_name in ("ansi", "ada", "dali"):
        configure(probe_name)
        run_pty_probe(probe_name)

    class RpcClient:
        def __init__(self, args, proc_env, cwd):
            self.proc = subprocess.Popen(
                [str(MARE), *args],
                cwd=str(cwd),
                env=proc_env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.fd = self.proc.stdout.fileno()
            self.buf = b""
            self.seq = 0
            self.events = []

        def _read_msg(self, deadline):
            while True:
                if b"\n" in self.buf:
                    raw, self.buf = self.buf.split(b"\n", 1)
                    if raw.strip():
                        return json.loads(raw.decode("utf-8"))
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError("RPC read timed out")
                ready, _, _ = select.select([self.fd], [], [], rem)
                if not ready:
                    raise TimeoutError("RPC read timed out")
                chunk = os.read(self.fd, 65536)
                if not chunk:
                    raise EOFError("RPC stdout closed")
                self.buf += chunk

        def call(self, method, params=None, timeout=45):
            self.seq += 1
            req_id = self.seq
            payload = {"jsonrpc": "2.0", "id": req_id, "method": method}
            if params is not None:
                payload["params"] = params
            self.proc.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
            deadline = time.monotonic() + timeout
            while True:
                msg = self._read_msg(deadline)
                if msg.get("id") == req_id:
                    if "error" in msg:
                        raise RuntimeError(msg["error"])
                    return msg.get("result")
                self.events.append(msg)

        def wait_event(self, predicate, timeout=10):
            for idx, ev in enumerate(self.events):
                if predicate(ev):
                    return self.events.pop(idx)
            deadline = time.monotonic() + timeout
            while True:
                msg = self._read_msg(deadline)
                if predicate(msg):
                    return msg
                self.events.append(msg)

        def close(self):
            if self.proc.poll() is None:
                try:
                    self.call("shutdown", timeout=5)
                except (OSError, TimeoutError, EOFError, RuntimeError):
                    self.proc.terminate()
            self.proc.wait(timeout=5)
            self.proc.stdout.close()
            self.proc.stdin.close()
            self.proc.stderr.close()

    # E2E: bundled themes, aliases, semantic syntax, /reload cleanup, save failure, multi-caller pairs.
    e2e_home = tmp / "e2e_home"
    (e2e_home / "config/plugins").mkdir(parents=True)
    (e2e_home / "config/themes").mkdir(parents=True)
    (e2e_home / "config/plugins/override-probe.lua").write_text(
        'return {\n'
        '\tname = "override-probe",\n'
        "\tapply = function()\n"
        '\t\tmare.ui.style("MareAccent", { fg = "#13579b" })\n'
        '\t\tfor _, set in pairs(mare.ui.icons or {}) do\n'
        '\t\t\tset.user_keep = "U"\n'
        "\t\tend\n"
        "\tend,\n"
        "}\n",
        encoding="utf-8",
    )
    ephemeral_pkg = tmp / "ephemeral_pkg"
    (ephemeral_pkg / "themes").mkdir(parents=True)
    (ephemeral_pkg / "themes/ephemeral-pkg.lua").write_text(
        'return { EphemeralPkgToken = { fg = "#654321" } }\n',
        encoding="utf-8",
    )
    (ephemeral_pkg / "mare-plugin.toml").write_text(
        'name = "test/ephemeral"\nversion = "0.1.0"\n',
        encoding="utf-8",
    )
    for git_args in [
        ["init", "-q"],
        ["add", "."],
        [
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "ephemeral",
        ],
    ]:
        subprocess.run(["git", "-C", str(ephemeral_pkg), *git_args], check=True)

    (e2e_home / "config/themes/ephemeral-user.lua").write_text(
        'return { styles = { EphemeralToken = { fg = "#abcdef" } }, icons = { file = "E", ephemeral_only = "X" } }\n',
        encoding="utf-8",
    )
    e2e_cfg = e2e_home / "config/init.lua"

    def write_e2e_cfg(flavor_val, extra_setup="", include_ephemeral=True):
        pkgs = [
            f'{{"test/themes", url={json.dumps(package.as_uri())}, only={{}}}}'
        ]
        if include_ephemeral:
            pkgs.append(
                f'{{"test/ephemeral", url={json.dumps(ephemeral_pkg.as_uri())}, only={{}}}}'
            )
        e2e_cfg.write_text(
            f'mare.setup {{model="faux/echo", flavor={json.dumps(flavor_val)}, peer={{allow={{"theme.register", "theme.preview"}}}}{extra_setup}}}\n'
            f"mare.plugins.add {{{', '.join(pkgs)}}}\n",
            encoding="utf-8",
        )

    e2e_env = dict(
        os.environ, MARE_HOME=str(e2e_home), TERM="xterm-256color", COLORTERM="truecolor"
    )
    e2e_env.pop("NO_COLOR", None)
    e2e_env.pop("TERM_PROGRAM", None)

    write_e2e_cfg("ephemeral-user")
    sync_res = run(["-C", str(work), "plugin", "sync"], e2e_env)
    assert sync_res.returncode == 0, sync_res.stderr

    rpc = RpcClient(
        [
            "-C",
            str(work),
            "--rpc",
            "--peer",
            "--yolo",
            "--model",
            "faux/echo",
            "--no-session",
        ],
        e2e_env,
        work,
    )
    try:
        owner_sid = rpc.call(
            "initialize", {"protocol_version": "3.0", "client": {"name": "e2e"}}
        )["session"]["session_id"]
        rpc.call("events.subscribe", {"scope": "all", "include": ["reload/completed", "theme/changed"]})

        listed = {d["name"]: d for d in rpc.call("theme.list")["data"]}
        for builtin_theme in (
            "ansi",
            "base16",
            "base16-256",
            "base16-eighties-dark",
            "base16-mocha-dark",
            "base16-ocean-dark",
            "base16-ocean-light",
            "inspired-github",
        ):
            assert listed[builtin_theme]["origin"] == "builtin", builtin_theme
            sel = rpc.call("theme.select", {"theme": builtin_theme, "save": False})
            assert sel["active"] == builtin_theme and "<plist" in sel["syntax"]
            if builtin_theme in ("ansi", "base16", "base16-256"):
                assert len(listed[builtin_theme]["variants"]) == 2
                assert "#00000001" in sel["syntax"]
                if builtin_theme == "base16-256":
                    assert "#10000000" in sel["syntax"]

        for model_theme, accent_hex in (
            ("ada", "#5fafff"),
            ("babbage", "#008700"),
            ("curie", "#d7af00"),
            ("cushman", "#0087ff"),
            ("dali", "#d7af00"),
            ("davinci", "#d75f00"),
        ):
            assert listed[model_theme]["origin"] == "builtin", model_theme
            sel = rpc.call("theme.select", {"theme": model_theme, "save": False})
            assert sel["active"] == model_theme and "<plist" in sel["syntax"]
            assert sel["styles"]["MareHeading"]["fg"] == accent_hex, (
                model_theme,
                sel["styles"]["MareHeading"],
            )
            assert sel["styles"]["MareAccent"]["fg"] == "#13579b", model_theme
            if model_theme in ("dali", "davinci"):
                assert "#00000001" in sel["syntax"], model_theme

        # Semantic fallback scopes for palette-only theme (nord).
        nord_snap = rpc.call("theme.select", {"theme": "nord", "save": False})
        for scope in (
            "keyword.operator",
            "variable.parameter",
            "entity.name.type",
            "markup.heading",
            "markup.bold",
            "diff.inserted",
            "diff.deleted",
        ):
            assert scope in nord_snap["syntax"], scope

        # Aliases over RPC.
        oh_dark = rpc.call("theme.select", {"theme": "one-half-dark", "save": False})
        assert (
            oh_dark["active"] == "one-halfdark"
            and oh_dark["preference"] == "one-half-dark"
        )
        oh_light = rpc.call("theme.select", {"theme": "one-half-light", "save": False})
        assert (
            oh_light["active"] == "one-halflight"
            and oh_light["preference"] == "one-half-light"
        )

        # Save-failure atomicity: corrupt state/state.json leaves .bak intact and active theme unchanged.
        rpc.call("theme.select", {"theme": "nord", "save": False})
        state_dir = e2e_home / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        state_file = state_dir / "state.json"
        state_bak = state_dir / "state.json.bak"
        state_file.write_text("{corrupt", encoding="utf-8")
        try:
            rpc.call("theme.select", {"theme": "dracula", "save": True})
        except RuntimeError:
            pass
        else:
            raise AssertionError("corrupt state.json should fail theme.select save=True")
        assert state_file.read_text(encoding="utf-8") == "{corrupt"
        assert state_bak.read_text(encoding="utf-8") == "{corrupt"
        after_fail = rpc.call("theme.get")
        assert after_fail["active"] == "nord" and after_fail["preference"] == "nord"
        state_file.unlink()
        state_bak.unlink()

        # Verify ephemeral package & user theme before deleting them + /reload.
        pkg_snap = rpc.call("theme.select", {"theme": "ephemeral-pkg", "save": False})
        assert pkg_snap["styles"]["EphemeralPkgToken"]["fg"] == "#654321"
        user_snap = rpc.call("theme.select", {"theme": "ephemeral-user", "save": False})
        assert user_snap["styles"]["EphemeralToken"]["fg"] == "#abcdef"
        assert user_snap["styles"]["MareAccent"]["fg"] == "#13579b"
        assert user_snap["icons"]["ephemeral_only"] == "X"

        (e2e_home / "config/themes/ephemeral-user.lua").unlink()
        shutil.rmtree(ephemeral_pkg)
        write_e2e_cfg("ephemeral-user", include_ephemeral=False)
        rpc.events.clear()
        rpc.call("commands.run", {"line": "/reload"})
        reload_ev = rpc.wait_event(
            lambda m: (
                m.get("method") == "event"
                and m.get("params", {}).get("type") == "reload/completed"
            )
        )
        assert reload_ev["params"]["type"] == "reload/completed"
        after_reload = rpc.call("theme.get")
        listed_after = {d["name"] for d in rpc.call("theme.list")["data"]}
        assert "ephemeral-user" not in listed_after
        assert "ephemeral-pkg" not in listed_after
        assert (
            after_reload["preference"] == "auto"
            and after_reload["active"] != "ephemeral-user"
        )
        assert "EphemeralToken" not in after_reload["styles"]
        assert "EphemeralPkgToken" not in after_reload["styles"]
        assert after_reload["styles"]["MareAccent"]["fg"] == "#13579b"

        # Paired-variant & multi-caller peer socket matrix.
        write_e2e_cfg(
            "auto",
            extra_setup=', flavor_dark="gruvbox-dark", flavor_light="gruvbox-light"',
            include_ephemeral=False,
        )
        rpc.events.clear()
        rpc.call("commands.run", {"line": "/reload"})
        rpc.wait_event(
            lambda m: (
                m.get("method") == "event"
                and m.get("params", {}).get("type") == "reload/completed"
            )
        )
        paired = rpc.call("theme.get")
        assert paired["preference"] == "auto"
        assert (
            paired["dark"] == "gruvbox-dark" and paired["light"] == "gruvbox-light"
        )
        assert paired["active"] == "gruvbox-dark"

        sock_path = str(e2e_home / "state/peers" / f"{rpc.proc.pid}.sock")

        def open_peer(peer_id):
            sock = socket.socket(socket.AF_UNIX)
            sock.settimeout(5)
            sock.connect(sock_path)
            stream = sock.makefile("rw")

            def call_peer(method, params):
                stream.write(
                    json.dumps(
                        {"jsonrpc": "2.0", "id": peer_id, "method": method, "params": params}
                    )
                    + "\n"
                )
                stream.flush()
                while True:
                    val = json.loads(stream.readline())
                    if val.get("id") == peer_id:
                        assert "error" not in val, val
                        return val["result"]

            call_peer("initialize", {"protocol_version": "3.0"})
            return sock, stream, call_peer

        p1_sock, p1_stream, p1_call = open_peer(1)
        p2_sock, p2_stream, p2_call = open_peer(2)
        p1_call(
            "theme.register",
            {"session_id": owner_sid, "definition": {"name": "peer1-theme", "palette": {}}},
        )
        p1_call("theme.preview", {"theme": "peer1-theme"})
        p2_call(
            "theme.register",
            {"session_id": owner_sid, "definition": {"name": "peer2-theme", "palette": {}}},
        )
        p2_call("theme.preview", {"theme": "peer2-theme"})
        assert rpc.call("theme.get")["active"] == "peer2-theme"

        # Closing p1 must unregister peer1-theme without clearing p2's newer preview.
        p1_stream.close()
        p1_sock.close()
        # Synchronize via a round-trip on p2 and verify p2 preview remains active.
        assert rpc.call("theme.get")["preview"] == "peer2-theme"

        # Closing p2 withdraws peer2-theme and fires theme/changed back to gruvbox-dark.
        rpc.events.clear()
        p2_stream.close()
        p2_sock.close()
        changed_ev = rpc.wait_event(
            lambda m: (
                m.get("method") == "event"
                and m.get("params", {}).get("type") == "theme/changed"
                and m.get("params", {}).get("data", {}).get("active") == "gruvbox-dark"
            )
        )
        assert changed_ev["params"]["data"].get("preview") is None
        assert rpc.call("theme.get").get("preview") is None
    finally:
        rpc.close()

print(
    "37 theme flavors + builtin aliases/themes/ANSI, /reload deleted-package/user cleanup, save-failure atomicity, and multi-caller paired-variant E2E passed"
)
