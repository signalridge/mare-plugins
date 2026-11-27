#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-ask_user_question-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/ask_user_question" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/ask-user-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" ASK_USER_CAPTURE="$tmp_root/requests.jsonl"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/ask_user_question", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"probe complete"}]' >"$tmp_root/probe-script.json"
export MARE_FAUX_SCRIPT="$tmp_root/probe-script.json" ASK_USER_REPORT="$tmp_root/probe-report.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --no-session 'run public API probes' >"$tmp_root/probe.txt"
jq -e '.ok == true and .detail == "passed"' "$ASK_USER_REPORT" >/dev/null || { cat "$ASK_USER_REPORT"; exit 1; }
printf "ask_user_question file:// faux contracts passed\n"
unset ASK_USER_REPORT
cat >"$tmp_root/probe-script.json" <<'JSON'
[{"tool_calls":[{"name":"ask_user_question","arguments":{"questions":[{"id":"target","header":"Target","question":"Which target?","options":[{"label":"A","description":"First","recommended":true},{"label":"B","description":"Second"}]}]}}]},{"text":"done"}]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'ask a question' >"$tmp_root/actual.jsonl"
jq -s -e 'tostring | contains("Nobody can answer")' "$tmp_root/actual.jsonl" >/dev/null
printf 'ask_user_question faux invocation reports no responder without guessing passed\n'
python3 "$repo_root/tests/e2e-ask-user-question-rpc.py" "$mare_bin" "$tmp_root/work" "$tmp_root"
python3 "$repo_root/tests/e2e-ask-user-question-pty.py" "$mare_bin" "$tmp_root/work" "$tmp_root"
