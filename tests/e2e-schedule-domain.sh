#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/schedule-domain.XXXXXX")"
cleanup() { local status=$?; if [[ "$status" -eq 0 || "$status" -eq 77 ]]; then rm -rf "$tmp_root"; else printf 'domain artifacts: %s\n' "$tmp_root" >&2; fi; }
trap cleanup EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/schedule" "$tmp_root/package/plugins/"
cp -R "$repo_root/plugins/plan-mode" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/schedule-domain-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home"
export DOMAIN_MODEL_LOG="$tmp_root/model.jsonl"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux-domain/echo" }
mare.plugins.add { { "test/schedule-domain", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
rc=0
python3 "$repo_root/tests/fixtures/schedule-domain-probe/drive.py" "$mare_bin" "$tmp_root/work" || rc=$?
[[ "$rc" -eq 0 ]] || exit "$rc" # 77: capability skip (printed by the driver)
printf 'schedule durable domain: file:// model CRUD, seven timings, CAS, restart, native receipts/history, errors/cancel and UI passed\n'
