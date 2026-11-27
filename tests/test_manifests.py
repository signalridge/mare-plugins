"""Exercise the manifest checker against isolated plugin repositories."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
VALIDATOR = pathlib.Path(__file__).with_name("manifests.py")
MANIFEST = "mare-plugin.toml"
LEGACY_MANIFEST = "mare-" + "pkg.toml"
RELEASE_MANIFEST = ".release-please-manifest.json"


class ManifestCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / "tests").mkdir()
        shutil.copy2(VALIDATOR, self.root / "tests" / "manifests.py")
        self.write_release_manifest("1.0.0")
        self.write_renames_table()
        self.write_manifest(self.root, "signalridge/mare-plugins")
        self.write_manifest(self.root / "plugins" / "alpha", "alpha")
        self.write_manifest(self.root / "plugins" / "beta", "beta")

    def write_release_manifest(self, version="1.0.0"):
        (self.root / RELEASE_MANIFEST).write_text(
            json.dumps({".": version}, indent=2) + "\n",
            encoding="utf-8",
        )

    def write_renames_table(self, content="[renamed]\n\n[deprecated]\n"):
        (self.root / "plugins.toml").write_text(content, encoding="utf-8")

    def write_manifest(
        self,
        directory,
        name,
        suffix="",
        *,
        version="1.0.0",
        write_news=True,
        write_readme=True,
    ):
        directory.mkdir(parents=True, exist_ok=True)
        version_line = f'version = "{version}"\n' if version is not None else ""
        (directory / MANIFEST).write_text(
            f'name = "{name}"\n{version_line}description = "Fixture plugin"\ncategory = "agent"\n'
            f'requires = ">=0.1.0"\n{suffix}',
            encoding="utf-8",
        )
        if directory != self.root:
            if write_news and version is not None:
                (directory / "NEWS.md").write_text(
                    f"# {name} news\n\n## {version}\n\n- Initial release.\n",
                    encoding="utf-8",
                )
            if write_readme:
                (directory / "README.md").write_text(
                    f"# {name}\n\nFixture plugin README.\n",
                    encoding="utf-8",
                )

    def check(self):
        return subprocess.run(
            [sys.executable, str(self.root / "tests" / "manifests.py")],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
            encoding="utf-8",
        )

    def assert_rejected(self, message):
        result = self.check()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(
            message, (result.stderr or result.stdout).strip().splitlines()[-1]
        )

    def test_valid_repository_and_root_repository_name(self):
        self.write_manifest(
            self.root / "plugins" / "beta",
            "beta",
            "plugins = []\n[deps]\nrequired = []\noptional = []\n",
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_plugin_names_must_be_unique_and_not_dot_prefixed(self):
        cases = (
            ("alpha", "duplicate plugin name"),
            ("agent.beta", "plugin name must not contain '.'"),
        )
        for name, message in cases:
            with self.subTest(name=name):
                self.write_manifest(self.root / "plugins" / "beta", name)
                self.assert_rejected(message)

    def test_requires_must_be_at_root_even_when_root_value_exists(self):
        for section in ("recommended", "deps", "provides"):
            with self.subTest(section=section):
                self.write_manifest(
                    self.root / "plugins" / "beta",
                    "beta",
                    f'[{section}]\nrequires = ">=1"\n',
                )
                self.assert_rejected(
                    f"`requires` must be at root, not inside [{section}]"
                )

    def test_requires_is_mandatory_for_root_and_plugins(self):
        for directory in (self.root, self.root / "plugins" / "beta"):
            with self.subTest(directory=directory):
                manifest = directory / MANIFEST
                original = manifest.read_text(encoding="utf-8")
                manifest.write_text('name = "named"\n', encoding="utf-8")
                self.assert_rejected("missing root `requires`")
                manifest.write_text(original, encoding="utf-8")

    def test_rejects_legacy_manifest_alongside_new_one(self):
        for directory in (
            self.root,
            self.root / "plugins" / "alpha",
            self.root / "tests" / "fixtures",
        ):
            with self.subTest(directory=directory):
                directory.mkdir(parents=True, exist_ok=True)
                legacy = directory / LEGACY_MANIFEST
                legacy.write_text('name = "old"\n', encoding="utf-8")
                self.assert_rejected("legacy manifest")
                legacy.unlink()

    def test_rejects_legacy_manifest_fields(self):
        for suffix, message in (
            ("extras" + " = []\n", "legacy extras field"),
            ("extensions" + " = []\n", "legacy extensions field"),
            ("[" + "packages" + "]\nrequired = []\n", "legacy packages section"),
        ):
            with self.subTest(message=message):
                self.write_manifest(self.root / "plugins" / "beta", "beta", suffix)
                self.assert_rejected(message)

    def test_rejects_legacy_plugin_field_inside_sections(self):
        legacy_key = "extras"
        for section in ("recommended", "deps"):
            with self.subTest(section=section):
                self.write_manifest(
                    self.root / "plugins" / "beta",
                    "beta",
                    f"[{section}]\n{legacy_key} = []\n",
                )
                self.assert_rejected("legacy extras field")

    def test_plugin_name_must_match_its_directory(self):
        self.write_manifest(self.root / "plugins" / "beta", "different")
        self.assert_rejected("must match directory")

    def test_plugin_references_must_exist(self):
        for field in ("plugins", "conflicts"):
            with self.subTest(field=field):
                self.write_manifest(
                    self.root / "plugins" / "beta", "beta", f'{field} = ["missing"]\n'
                )
                self.assert_rejected(f"unknown plugin in {field}")
        self.write_manifest(
            self.root / "plugins" / "beta",
            "beta",
            'plugins = ["alpha"]\nconflicts = ["alpha"]\n',
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_plugin_references_are_string_arrays(self):
        for field in ("plugins", "conflicts"):
            for value in ('"alpha"', "[7]", '[" "]'):
                with self.subTest(field=field, value=value):
                    self.write_manifest(
                        self.root / "plugins" / "beta", "beta", f"{field} = {value}\n"
                    )
                    self.assert_rejected(f"invalid {field}")

    def test_rejects_invalid_platforms(self):
        for value in (
            '["solaris"]',
            '["darwin"]',
            '["win32"]',
            '["wsl"]',
            '"linux"',
            '["linux", ""]',
        ):
            with self.subTest(value=value):
                self.write_manifest(
                    self.root / "plugins" / "beta", "beta", f"platforms = {value}\n"
                )
                self.assert_rejected("invalid platforms")
        self.write_manifest(
            self.root / "plugins" / "beta",
            "beta",
            'platforms = ["linux", "macos", "windows"]\n',
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_invalid_provides(self):
        for entry in (
            'tools = "tool"',
            "tools = []",
            'tools = ["ok", 1]',
            'tools = [" "]',
            'bogus = ["value"]',
        ):
            with self.subTest(entry=entry):
                self.write_manifest(
                    self.root / "plugins" / "beta", "beta", f"[provides]\n{entry}\n"
                )
                self.assert_rejected("invalid provides")
        self.write_manifest(
            self.root / "plugins" / "beta", "beta", 'provides = "tool"\n'
        )
        self.assert_rejected("invalid provides")

    def test_all_supported_provides_keys_accept_nonempty_arrays(self):
        keys = (
            "tools",
            "commands",
            "hooks",
            "skills",
            "prompts",
            "themes",
            "services",
            "flags",
            "mcp",
        )
        fields = "".join(f'{key} = ["value"]\n' for key in keys)
        self.write_manifest(
            self.root / "plugins" / "beta", "beta", "[provides]\n" + fields
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_dependency_table_has_string_arrays(self):
        for suffix in (
            'deps = "wrong"\n',
            '[deps]\nrequired = "bad"\n',
            "[deps]\noptional = [1]\n",
        ):
            with self.subTest(suffix=suffix):
                self.write_manifest(self.root / "plugins" / "beta", "beta", suffix)
                self.assert_rejected("invalid deps")

    def test_root_manifest_must_exist_and_parse(self):
        manifest = self.root / MANIFEST
        manifest.unlink()
        self.assertNotEqual(self.check().returncode, 0)
        manifest.write_text("not valid TOML [", encoding="utf-8")
        self.assertNotEqual(self.check().returncode, 0)

    def test_description_category_and_version_are_validated(self):
        manifest = self.root / "plugins" / "beta" / MANIFEST
        original = manifest.read_text(encoding="utf-8")
        for before, after, message in (
            ('description = "Fixture plugin"', 'description = " "', "description"),
            ('category = "agent"', 'category = "unknown"', "invalid category"),
            ('category = "agent"', 'category = ["agent"]', "invalid category"),
            ('requires = ">=0.1.0"', 'requires = ">=oops"', "semver"),
        ):
            with self.subTest(after=after):
                manifest.write_text(original.replace(before, after), encoding="utf-8")
                self.assert_rejected(message)
        manifest.write_text(original, encoding="utf-8")

    def test_semver_ranges_follow_core_version_requirement_syntax(self):
        manifest = self.root / "plugins" / "beta" / MANIFEST
        original = manifest.read_text(encoding="utf-8")
        valid = ("*", "1", "^1.2", "1.2.*", ">= 1.2.3-alpha.1+build.2, < 2")
        invalid = (
            "banana",
            "1.2.3.4",
            "01.2.3",
            "1.2-alpha",
            ">=1 <2",
            "1.*.3",
            "1.2.3-01",
            "* , >=1",
            "18446744073709551616.0.0",
        )
        for requirement in valid:
            with self.subTest(valid=requirement):
                manifest.write_text(
                    original.replace(">=0.1.0", requirement), encoding="utf-8"
                )
                result = self.check()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for requirement in invalid:
            with self.subTest(invalid=requirement):
                manifest.write_text(
                    original.replace(">=0.1.0", requirement), encoding="utf-8"
                )
                self.assert_rejected("semver")
        manifest.write_text(original, encoding="utf-8")

    def test_rejects_recommended_lua_even_if_the_file_exists(self):
        for directory, name in (
            (self.root, "signalridge/mare-plugins"),
            (self.root / "plugins" / "beta", "beta"),
        ):
            for value in ('"recommend.lua"', '"missing.lua"', "false"):
                with self.subTest(directory=directory, value=value):
                    self.write_manifest(self.root, "signalridge/mare-plugins")
                    self.write_manifest(self.root / "plugins" / "beta", "beta")
                    (directory / "recommend.lua").write_text("return true", encoding="utf-8")
                    self.write_manifest(directory, name, f"[recommended]\nlua = {value}\n")
                    self.assert_rejected("recommended.lua is not supported")

    def test_recommended_declarative_fields_are_allowed(self):
        self.write_manifest(
            self.root / "plugins" / "beta",
            "beta",
            '[recommended]\nroot = ["Cargo.toml"]\ncmd = ["git"]\n',
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        self.write_manifest(
            self.root / "plugins" / "beta",
            "beta",
            '[recommended]\nroot = ["Cargo.toml"]\ncmd = ["git"]\nenv = ["CI"]\n',
        )
        self.assert_rejected("unsupported recommended fields")

    def test_web_directory_is_required_and_must_exist(self):
        beta = self.root / "plugins" / "beta"
        self.write_manifest(beta, "beta", '[web]\nprefix = "/ui"\n')
        self.assert_rejected("missing web.dir")
        self.write_manifest(beta, "beta", '[web]\ndir = "web"\n')
        self.assert_rejected("web.dir")
        (beta / "web").mkdir()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_web_directory_cannot_point_outside_the_plugin(self):
        alpha = self.root / "plugins" / "alpha"
        beta = self.root / "plugins" / "beta"
        (alpha / "web").mkdir()
        self.write_manifest(beta, "beta", '[web]\ndir = "../alpha/web"\n')
        self.assert_rejected("web.dir")

    def test_root_optional_metadata_is_validated(self):
        self.write_manifest(
            self.root, "signalridge/mare-plugins", '[web]\ndir = "web"\n'
        )
        self.assert_rejected("web.dir")
        (self.root / "web").mkdir()
        self.write_manifest(
            self.root, "signalridge/mare-plugins", '[provides]\ntools = "bad"\n'
        )
        self.assert_rejected("invalid provides")

    def test_rejects_missing_plugin_manifest(self):
        (self.root / "plugins" / "beta" / MANIFEST).unlink()
        self.assert_rejected("missing plugin manifests")

    def test_manifest_versions_must_match_release_please_manifest(self):
        for directory, name in (
            (self.root, "signalridge/mare-plugins"),
            (self.root / "plugins" / "beta", "beta"),
        ):
            with self.subTest(case="missing", directory=directory):
                self.write_manifest(directory, name, version=None)
                self.assert_rejected("missing root `version`")
                self.write_manifest(directory, name, version="1.0.0")
            with self.subTest(case="mismatch", directory=directory):
                self.write_manifest(directory, name, version="2.0.0")
                self.assert_rejected("does not match .release-please-manifest.json")
                self.write_manifest(directory, name, version="1.0.0")

        release_manifest = self.root / RELEASE_MANIFEST
        release_manifest.write_text("{}\n", encoding="utf-8")
        self.assert_rejected(".release-please-manifest.json")
        release_manifest.unlink()
        self.assert_rejected(".release-please-manifest.json")

    def test_release_please_config_tracks_all_manifests(self):
        config = json.loads(
            (REPO_ROOT / "release-please-config.json").read_text(encoding="utf-8")
        )
        extra_files = config["packages"]["."]["extra-files"]
        self.assertIn(
            {
                "type": "toml",
                "path": "mare-plugin.toml",
                "jsonpath": "$.version",
            },
            extra_files,
        )
        self.assertIn(
            {
                "type": "toml",
                "path": "plugins/*/mare-plugin.toml",
                "jsonpath": "$.version",
                "glob": True,
            },
            extra_files,
        )
        plugin_manifests = sorted(REPO_ROOT.glob("plugins/*/mare-plugin.toml"))
        self.assertEqual(len(plugin_manifests), 20)

    def test_plugins_require_readme_and_matching_news_section(self):
        beta = self.root / "plugins" / "beta"
        (beta / "README.md").unlink()
        self.assert_rejected("missing plugin README.md")
        (beta / "README.md").write_text("# beta\n", encoding="utf-8")

        (beta / "NEWS.md").unlink()
        self.assert_rejected("missing plugin NEWS.md")
        (beta / "NEWS.md").write_text("# beta news\n\n## 0.9.0\n\n- Old.\n", encoding="utf-8")
        self.assert_rejected("NEWS.md missing section for version '1.0.0'")
        (beta / "NEWS.md").write_text("# beta news\n\n## 1.0.0\n\n", encoding="utf-8")
        self.assert_rejected("NEWS.md missing section for version '1.0.0'")

    def test_plugins_toml_rename_table_is_required_and_validated(self):
        (self.root / "plugins.toml").unlink()
        self.assert_rejected("missing plugins.toml")

        self.write_renames_table('[unknown]\na = "b"\n')
        self.assert_rejected("unsupported plugins.toml sections")

        self.write_renames_table('[renamed]\nold-name = "missing"\n')
        self.assert_rejected("unknown target plugin")

        self.write_renames_table('[renamed]\nalpha = "beta"\n')
        self.assert_rejected("conflicts with active plugin")

        self.write_renames_table('[deprecated]\nalpha = "removed"\n')
        self.assert_rejected("conflicts with active plugin")

        self.write_renames_table('[renamed]\nold-beta = "beta"\n\n[deprecated]\nold-gone = "retired"\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_third_party_themes_require_notices_entries(self):
        syntax_dir = self.root / "themes" / "syntax"
        syntax_dir.mkdir(parents=True)
        (syntax_dir / "sample.tmTheme").write_text("<plist version=\"1.0\"></plist>\n", encoding="utf-8")
        (self.root / "themes" / "inline.lua").write_text(
            'return { syntax = [=[<plist version="1.0"></plist>]=] }\n',
            encoding="utf-8",
        )
        (self.root / "themes" / "palette-only.lua").write_text(
            'return { base = "dark", palette = {} }\n',
            encoding="utf-8",
        )
        self.assert_rejected("missing THIRD_PARTY_NOTICES.md")

        notices = self.root / "THIRD_PARTY_NOTICES.md"
        license_markers = (
            "Permission is hereby granted, free of charge\n"
            "Redistribution and use in source and binary forms\n"
        )
        notices.write_text(
            "themes/syntax/sample.tmTheme\n" + license_markers,
            encoding="utf-8",
        )
        self.assert_rejected("THIRD_PARTY_NOTICES.md missing third-party theme: themes/inline.lua")

        notices.write_text(
            "themes/inline.lua\n" + license_markers,
            encoding="utf-8",
        )
        self.assert_rejected(
            "THIRD_PARTY_NOTICES.md missing third-party theme: themes/syntax/sample.tmTheme"
        )

        notices.write_text(
            "themes/syntax/sample.tmTheme\nthemes/inline.lua\n" + license_markers,
            encoding="utf-8",
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_repo_third_party_notices_cover_all_13_themes(self):
        tm_files = sorted((REPO_ROOT / "themes" / "syntax").glob("*.tmTheme"))
        inline_files = sorted(
            p
            for p in (REPO_ROOT / "themes").glob("*.lua")
            if "<plist" in p.read_text(encoding="utf-8", errors="replace")
        )
        self.assertEqual(len(tm_files), 8)
        self.assertEqual(len(inline_files), 5)

    def test_rejects_undeclared_plugin_hooks(self):
        plugin_dir = self.root / "plugins" / "alpha"
        (plugin_dir / "init.lua").write_text(
            'return { name = "alpha", apply = function(ctx) ctx:on("option/changed", function() end) end }\n',
            encoding="utf-8",
        )
        self.assert_rejected("[provides].hooks missing subscribed events ['option/changed']")

        self.write_manifest(
            plugin_dir,
            "alpha",
            '[provides]\nhooks = ["option/changed"]\n',
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
