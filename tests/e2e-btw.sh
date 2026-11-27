#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-btw-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/btw" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/btw-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture

export MARE_HOME="$tmp_root/home"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup {
  model = "faux/echo",
}
mare.plugins.add { { "test/btw", url = "file://$tmp_root/package" } }
LUA

"$mare_bin" -C "$tmp_root/work" plugin sync

printf '[{"text":"probe complete"}]' >"$tmp_root/probe-script.json"
MARE_FAUX_SCRIPT="$tmp_root/probe-script.json" BTW_PROBE_REPORT="$tmp_root/probe-report.json" \
  "$mare_bin" -C "$tmp_root/work" -p --no-session 'run btw probes' >"$tmp_root/probe.txt"
jq -e '.ok == true and .detail == "passed"' "$tmp_root/probe-report.json" >/dev/null \
  || { cat "$tmp_root/probe-report.json"; exit 1; }

python3 "$repo_root/tests/e2e-btw.py" "$mare_bin" "$tmp_root/work" "$tmp_root"
printf 'mare-plugins: btw file:// contracts, RPC, concurrent parent, model freeze, and PTY passed\n'
