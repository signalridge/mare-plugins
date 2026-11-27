"""Unit tests for scripts/lua_api_rules.py (public API and underscore boundary checks)."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "lua_api_rules.py"


class LuaApiRulesTests(unittest.TestCase):
    def run_checker(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
            encoding="utf-8",
        )

    def test_detects_private_mare_ui_and_cordis_underscores(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            plugin = root / "plugins" / "demo" / "init.lua"
            plugin.parent.mkdir(parents=True)
            plugin.write_text(
                "\n".join(
                    [
                        "local a = mare._secret",
                        "local b = (ui)._hidden()",
                        'local c = mare["\\95escaped"]',
                        'local d = rawget(ui, "_raw")',
                        'rawset(mare, "_set", true)',
                        "local e = root.registry._internal",
                        "local f = fiber._error",
                        "local g = loaderFiber._store",
                        "local h = events._hooks",
                        "events:_resolve('emit')",
                        "ctx._disposables = {}",
                        "local i = ctx.root",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            res = self.run_checker("--root", str(root))
            self.assertNotEqual(res.returncode, 0, res.stdout)
            output = res.stdout + res.stderr
            for needle in (
                "mare._secret",
                "ui._hidden",
                "mare._escaped",
                "ui._raw",
                "mare._set",
                "root.registry._internal",
                "fiber._error",
                "loaderFiber._store",
                "events._hooks",
                "events._resolve",
                "ctx._disposables",
                "ctx.root",
            ):
                self.assertIn(needle, output)

    def test_detects_undeclared_imports_and_legacy_ctx_apis(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            pdir = root / "plugins" / "demo"
            (pdir / "lua" / "demo").mkdir(parents=True)
            (pdir / "lua" / "demo" / "ok.lua").write_text("return {}\n", encoding="utf-8")
            (pdir / "init.lua").write_text(
                "\n".join(
                    [
                        'local ok = require("demo.ok")',
                        'local lib = require("mare_lib")',
                        'local bad = require("other.mod")',
                        "local dyn = require(name)",
                        "local pkg = package.loaded",
                        "local env = _ENV",
                        'local g = _G["mare"]',
                        "ctx:on_dispose(function() end)",
                        'ctx:on("ev", fn, { priority = 1 })',
                        'ctx:emit("session/started", {})',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            res = self.run_checker("--root", str(root))
            self.assertNotEqual(res.returncode, 0, res.stdout)
            output = res.stdout + res.stderr
            self.assertNotIn("demo.ok", output)
            self.assertNotIn("mare_lib", output)
            for needle in (
                "other.mod",
                "unresolved dynamic import",
                "package",
                "_ENV",
                "_G",
                "on_dispose",
                "priority",
                "session/started",
            ):
                self.assertIn(needle, output)

    def test_respects_types_dir_public_modules_and_events(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            types_dir = root / "mare-types"
            (types_dir / "mare").mkdir(parents=True)
            (types_dir / "custom_pub.lua").write_text("---@meta custom_pub\n", encoding="utf-8")
            (types_dir / "mare" / "events.gen.lua").write_text(
                "--- `custom/event` (`mode = emit`)\n", encoding="utf-8"
            )
            pdir = root / "plugins" / "demo"
            pdir.mkdir(parents=True)
            (pdir / "init.lua").write_text(
                "\n".join(
                    [
                        'local pub = require("custom_pub")',
                        'ctx.bus:emit("custom/event", {})',
                        'ctx:emit("custom/event", {})',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            res = self.run_checker("--root", str(root), "--types-dir", str(types_dir))
            self.assertNotEqual(res.returncode, 0, res.stdout)
            output = res.stdout + res.stderr
            self.assertNotIn("custom_pub", output)
            self.assertIn("custom/event", output)
            # Only the bare ctx:emit on line 3 should fail, not ctx.bus:emit on line 2.
            self.assertIn("init.lua:3:", output)
            self.assertNotIn("init.lua:2:", output)


if __name__ == "__main__":
    unittest.main()
