#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-schedule-e2e.XXXXXX")"
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    printf 'schedule E2E artifacts retained at %s\n' "$tmp_root" >&2
  else
    rm -rf "$tmp_root"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/schedule" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/schedule-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" SCHEDULE_REPORT="$tmp_root/report.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux-schedule/echo" }
mare.plugins.add { { "test/schedule", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
python3 "$repo_root/tests/fixtures/schedule-probe/drive.py" "$mare_bin" "$tmp_root/work" "$SCHEDULE_REPORT"
printf 'mare-plugins: schedule file://, direct /loop/UI notifications, no-rewrite faux tool parameters, repeats, error/resume and session reset passed\n'
