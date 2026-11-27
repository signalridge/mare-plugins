"""Policy tests for GitHub Actions workflows, Dependabot, and CHANGELOG consistency."""

from __future__ import annotations

import json
import pathlib
import re
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
USES_RE = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.M)
SHA_PIN_RE = re.compile(r"^[^@]+@[0-9a-f]{40}$")
SEMVER_TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class CiPolicyTests(unittest.TestCase):
    def test_all_workflow_actions_are_sha_pinned(self) -> None:
        workflows = sorted(
            [*WORKFLOWS_DIR.glob("*.yml"), *WORKFLOWS_DIR.glob("*.yaml")]
        )
        self.assertTrue(workflows, "expected workflow files")
        for wf in workflows:
            text = wf.read_text(encoding="utf-8")
            uses = USES_RE.findall(text)
            self.assertTrue(uses, f"{wf.name}: expected at least one action")
            for ref in uses:
                if ref.startswith("./"):
                    continue
                self.assertRegex(
                    ref,
                    SHA_PIN_RE,
                    f"{wf.name}: action must be pinned to a 40-char commit SHA: {ref}",
                )

    def test_version_files_are_valid_single_sources(self) -> None:
        mare_version_file = REPO_ROOT / ".mare-version"
        self.assertTrue(mare_version_file.is_file(), "missing .mare-version file")
        mare_version = mare_version_file.read_text(encoding="utf-8").strip()
        self.assertRegex(
            mare_version,
            SEMVER_TAG_RE,
            f".mare-version must be a release tag like v1.0.0, got {mare_version!r}",
        )

        tools_file = REPO_ROOT / ".github" / "ci-tools.json"
        self.assertTrue(tools_file.is_file(), "missing .github/ci-tools.json")
        tools = json.loads(tools_file.read_text(encoding="utf-8"))
        self.assertRegex(
            str(tools.get("stylua", "")),
            SEMVER_RE,
            "ci-tools.json stylua version must be semver",
        )
        ast_grep = tools.get("ast_grep")
        self.assertIsInstance(ast_grep, dict, "ci-tools.json must define ast_grep")
        self.assertRegex(
            str(ast_grep.get("version", "")),
            SEMVER_RE,
            "ci-tools.json ast_grep.version must be semver",
        )
        self.assertRegex(
            str(ast_grep.get("sha256", "")),
            SHA256_RE,
            "ci-tools.json ast_grep.sha256 must be 64-char hex",
        )

    def test_ci_workflow_reads_version_files_and_verifies_mare_via_cosign(self) -> None:
        ci = (WORKFLOWS_DIR / "ci.yml").read_text(encoding="utf-8")
        self.assertRegex(
            ci,
            r"(?ms)^  pull_request:\s*\n    branches:\s*\[main\]",
            "ci.yml must filter pull_request to branches: [main]",
        )
        # No hardcoded tool versions or archive SHA256 digests in ci.yml.
        for forbidden in (
            r"(?m)^\s*MARE_VERSION\s*:",
            r"(?m)^\s*MARE_ARCHIVE_SHA256\s*:",
            r"(?m)^\s*AST_GREP_VERSION\s*:",
            r"(?m)^\s*AST_GREP_SHA256\s*:",
            r"(?m)^\s*version:\s*v?\d+\.\d+\.\d+",
            r"(?m)^\s*version:\s*latest\b",
        ):
            self.assertNotRegex(
                ci,
                forbidden,
                f"ci.yml must read versions from version files instead of hardcoding ({forbidden})",
            )

        self.assertIn(".mare-version", ci)
        self.assertIn(".github/ci-tools.json", ci)
        self.assertRegex(ci, r"(?m)^\s*python3 scripts/lua_api_rules\.py --self-test\s*$")
        self.assertRegex(ci, r"(?m)^\s*python3 scripts/lua_api_rules\.py\s*$")
        self.assertIn("./tests/run-specs.sh", ci)

        # Mare release integrity is verified via cosign bundle + checksums.txt.
        self.assertRegex(
            ci,
            r"uses:\s*sigstore/cosign-installer@[0-9a-f]{40}",
            "ci.yml must install cosign via SHA-pinned sigstore/cosign-installer",
        )
        self.assertIn("checksums.txt", ci)
        self.assertIn("checksums.txt.sigstore.json", ci)
        self.assertIn("cosign verify-blob", ci)
        self.assertIn(
            "--certificate-identity",
            ci,
            "cosign verify-blob must pin --certificate-identity",
        )
        self.assertIn(
            "https://github.com/signalridge/mare/.github/workflows/release.yaml@refs/tags/",
            ci,
        )
        self.assertIn(
            "https://token.actions.githubusercontent.com",
            ci,
            "cosign verify-blob must pin GitHub Actions OIDC issuer",
        )
        self.assertIn("sha256sum -c", ci)

    def test_ci_deps_update_workflow_automates_version_prs(self) -> None:
        wf_path = WORKFLOWS_DIR / "ci-deps-update.yaml"
        self.assertTrue(wf_path.is_file(), "missing .github/workflows/ci-deps-update.yaml")
        wf = wf_path.read_text(encoding="utf-8")
        self.assertRegex(wf, r"(?m)^  schedule:", "ci-deps-update.yaml must run on a schedule")
        self.assertRegex(
            wf, r"(?m)^  workflow_dispatch:", "ci-deps-update.yaml must support workflow_dispatch"
        )
        self.assertIn(".mare-version", wf)
        self.assertIn(".github/ci-tools.json", wf)
        self.assertRegex(
            wf,
            r"uses:\s*peter-evans/create-pull-request@[0-9a-f]{40}",
            "ci-deps-update.yaml must open PRs via SHA-pinned peter-evans/create-pull-request",
        )

    def test_dependabot_covers_github_actions(self) -> None:
        dep = (REPO_ROOT / ".github" / "dependabot.yml").read_text(encoding="utf-8")
        self.assertIn("package-ecosystem: github-actions", dep)

    def test_changelog_and_news_cover_release_version(self) -> None:
        version = json.loads(
            (REPO_ROOT / ".release-please-manifest.json").read_text(encoding="utf-8")
        )["."]
        changelog = (REPO_ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertRegex(
            changelog,
            rf"(?m)^##\s+{re.escape(version)}\b",
            f"CHANGELOG.md must contain a section for {version}",
        )
        news = (REPO_ROOT / "NEWS.md").read_text(encoding="utf-8")
        self.assertRegex(
            news,
            rf"(?m)^##\s+{re.escape(version)}\b",
            f"NEWS.md must contain a section for {version}",
        )

    def test_specs_job_skips_explicitly_before_v1_and_enforces_after_v1_exists(self) -> None:
        import os
        import stat
        import subprocess
        import tempfile

        ci = (WORKFLOWS_DIR / "ci.yml").read_text(encoding="utf-8")
        # specs must be gated at the job level so missing pre-v1.0.0 release marks specs explicitly skipped.
        self.assertRegex(
            ci,
            r"(?ms)^  check-mare-release:\n.*?^  specs:\n.*?^\s+needs:\s*\[check-mare-release\]\n.*?^\s+if:\s*needs\.check-mare-release\.outputs\.available == 'true'",
            "specs job must depend on check-mare-release and skip at job level when available != 'true'",
        )

        # Extract the check-mare-release run block and test its HTTP 200 / 404 / v1.0.0 enforcement contract.
        m = re.search(
            r"(?ms)^  check-mare-release:\n.*?^\s+run:\s*\|\n(.*?)(?=^  specs:)",
            ci,
        )
        self.assertIsNotNone(m, "could not extract check-mare-release script from ci.yml")
        raw_lines = m.group(1).splitlines()
        indents = [len(line) - len(line.lstrip(" ")) for line in raw_lines if line.strip()]
        min_indent = min(indents)
        script = "\n".join(line[min_indent:] if len(line) >= min_indent else "" for line in raw_lines) + "\n"

        cases = [
            # (name, mare_ver, target_http, v1_http, want_rc, want_avail)
            ("bootstrap_v1_missing_skips", "v1.0.0", "404", "404", 0, "false"),
            ("v1_published_runs", "v1.0.0", "200", "200", 0, "true"),
            ("after_v1_published_missing_target_fails", "v1.1.0", "404", "200", 1, None),
            ("before_v1_published_non_v1_typo_fails", "v9.9.9", "404", "404", 1, None),
            ("api_error_fails", "v1.0.0", "500", "500", 1, None),
        ]
        for name, mare_ver, target_http, v1_http, want_rc, want_avail in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as tmp:
                d = pathlib.Path(tmp)
                (d / ".mare-version").write_text(f"{mare_ver}\n", encoding="utf-8")
                (d / ".github").mkdir()
                (d / ".github" / "ci-tools.json").write_text(
                    '{"stylua":"2.6.0","ast_grep":{"version":"0.51.2","sha256":"' + "a" * 64 + '"}}\n',
                    encoding="utf-8",
                )
                bindir = d / "bin"
                bindir.mkdir()
                curl_bin = bindir / "curl"
                curl_bin.write_text(
                    "#!/bin/sh\n"
                    'url=""\n'
                    'for arg in "$@"; do url="$arg"; done\n'
                    'case "$url" in\n'
                    '  */releases/tags/v1.0.0) printf "%s" "$FAKE_V1_HTTP" ;;\n'
                    '  */releases/tags/*) printf "%s" "$FAKE_TARGET_HTTP" ;;\n'
                    '  *) exit 64 ;;\n'
                    "esac\n",
                    encoding="utf-8",
                )
                curl_bin.chmod(stat.S_IRWXU)
                out = d / "github_output"
                out.write_text("", encoding="utf-8")
                env = dict(
                    os.environ,
                    PATH=str(bindir) + os.pathsep + os.environ.get("PATH", ""),
                    GH_TOKEN="fake-token",
                    GITHUB_OUTPUT=str(out),
                    FAKE_TARGET_HTTP=target_http,
                    FAKE_V1_HTTP=v1_http,
                )
                res = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", script],
                    cwd=d,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                    encoding="utf-8",
                )
                if want_rc == 0:
                    self.assertEqual(res.returncode, 0, f"{name}: {res.stdout}{res.stderr}")
                    self.assertIn(f"available={want_avail}", out.read_text(encoding="utf-8"))
                else:
                    self.assertNotEqual(res.returncode, 0, f"{name}: expected failure: {res.stdout}{res.stderr}")


if __name__ == "__main__":
    unittest.main()
