#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-time-context-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/time-context" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/time-context-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" TIME_CAPTURE="$tmp_root/requests.jsonl" TIME_SESSION="$tmp_root/session.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "time-faux/echo", fallback_models = { "time-faux/echo2" } }
mare.plugins.add { { "test/time-context", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"error":"unknown model","kind":"model_not_found","retryable":false},{"text":"fallback answer"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
"$mare_bin" -C "$tmp_root/work" -p --session-id time-e2e 'real user input' >"$tmp_root/run.txt"
jq -s -e '
 length == 2 and .[0].model == "time-faux/echo" and .[1].model == "time-faux/echo2" and
 all(.[];
   ([.messages[] | select(.context_disclosure.namespace? == "time-context")]|length) == 1 and
   ([.messages[] | select(.context_disclosure.namespace? == "time-context") | .content[].text] | join("\n") | test("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}")) and
   (.cached_system | contains("<time_context") | not) and
   (.messages == (.history | map(del(.turn_id)))) and
   ([.messages[] | select(.role == "user" and .notification != true) | .content[] | select(.type == "text") | .text] == ["real user input"])
 )' "$TIME_CAPTURE" >/dev/null
jq -e 'tostring | contains("<time_context")' "$TIME_SESSION" >/dev/null
# Resume restores the source fact and the model executes a real read-only tool loop.
: >"$TIME_CAPTURE"
printf '[{"tool_calls":[{"name":"time_probe","arguments":{}}]},{"text":"resumed answer"}]' >"$tmp_root/script.json"
"$mare_bin" -C "$tmp_root/work" -p --resume time-e2e 'second real input' >"$tmp_root/resume.txt"
jq -s -e 'length == 2 and all(.[]; ([.messages[] | select(.context_disclosure.namespace? == "time-context")]|length) == 1 and (.messages == (.history | map(del(.turn_id)))) and (.cached_system | contains("<time_context")|not)) and (.[1].messages | any(.role == "tool_result"))' "$TIME_CAPTURE" >/dev/null
jq -e 'tostring | contains("<time_context")' "$TIME_SESSION" >/dev/null
printf 'time-context file:// faux durable source, unchanged system cache, fallback, resume and real tool loop passed\n'

had_skip=0
run_step() {
  local rc=0
  "$@" || rc=$?
  if [[ $rc -eq 77 ]]; then
    had_skip=1
    return 0
  fi
  return "$rc"
}

run_step python3 "$repo_root/tests/time-context-tui.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"

python3 "$repo_root/tests/time-context-rpc.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"

python3 "$repo_root/tests/time-context-clock.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"

TZ=Asia/Tokyo TIME_SAMPLE_SERIES='[1794668340000,1794668460000]' TIME_TUI_CLOCK=1 \
  run_step python3 "$repo_root/tests/time-context-tui.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"

python3 "$repo_root/tests/time-context-admission.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"

python3 "$repo_root/tests/time-context-retry.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"

if [[ $had_skip -eq 1 ]]; then
  exit 77
fi
