#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-todo-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/todo" "$tmp_root/package/plugins/"
cp -R "$repo_root/plugins/plan-mode" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/todo-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" TODO_CAPTURE="$tmp_root/requests.jsonl"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/todo", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"probe complete"}]' >"$tmp_root/probe-script.json"
export MARE_FAUX_SCRIPT="$tmp_root/probe-script.json" TODO_PROBE_REPORT="$tmp_root/probe-report.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --no-session 'run public API probes' >"$tmp_root/probe.txt"
jq -e '.ok == true and .detail == "passed"' "$TODO_PROBE_REPORT" >/dev/null || { cat "$TODO_PROBE_REPORT"; exit 1; }
unset TODO_PROBE_REPORT
: >"$TODO_CAPTURE"
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"todo_write","arguments":{"todos":[{"content":"first step {{literal}}","status":"in_progress"},{"content":"second step","status":"pending"}]}}]},
 {"tool_calls":[{"name":"todo_write","arguments":{"todos":[{"content":"replacement only","status":"completed"}]}}]},
 {"text":"done"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id todo-e2e 'track work' >"$tmp_root/run.jsonl"
jq -s -e 'length == 3 and (.[0].tools | any(.[]; .name == "todo_write")) and (.[0].system | contains("first step") | not) and (.[1].system | contains("first step {{literal}}")) and (.[2].system | contains("replacement only")) and (.[2].system | contains("first step") | not)' "$TODO_CAPTURE" >/dev/null
# Results must contain model-visible content, including both the canonical list and counts.
jq -s -e 'tostring | contains("replacement only") and contains("counts")' "$tmp_root/run.jsonl" >/dev/null
printf '[{"text":"fresh work"}]' >"$tmp_root/script.json"
: >"$TODO_CAPTURE"
"$mare_bin" -C "$tmp_root/work" --yolo -p --resume todo-e2e 'new user work' >"$tmp_root/resume.txt"
jq -s -e 'length == 1 and (.[0].system | contains("replacement only") | not)' "$TODO_CAPTURE" >/dev/null
# Ephemeral sessions must still support checklist writes without persistence.
printf '[{"tool_calls":[{"name":"todo_write","arguments":{"todos":[]}}]},{"text":"ephemeral done"}]' >"$tmp_root/script.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'ephemeral work' >"$tmp_root/ephemeral.jsonl"
jq -s -e 'tostring | contains("counts")' "$tmp_root/ephemeral.jsonl" >/dev/null
python3 "$repo_root/tests/todo-rpc.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"
python3 "$repo_root/tests/todo-tui.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"
printf 'mare-plugins: todo file:// contracts, faux requests, resume and ephemeral session passed\n'
