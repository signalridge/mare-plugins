#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-session-title-e2e.XXXXXX")"
trap 'if [[ ${TITLE_KEEP:-0} != 1 ]]; then rm -rf "$tmp_root"; fi' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/session-title" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/session-title-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" TITLE_CAPTURE="$tmp_root/requests.jsonl" TITLE_RESULT="$tmp_root/result.json" TITLE_CAPS="$tmp_root/caps.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/session-title", url = "file://$tmp_root/package" } }
mare.plugin("session-title", {automatic=mare.env("TITLE_ALL") and "all-prompts" or "first-prompt", llm=not mare.env("TITLE_CUSTOM"), timeout_ms=mare.env("TITLE_CUSTOM")=="timeout" and 40 or 15000})
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"main response","delay_ms":150},{"text":"Generated title"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
"$mare_bin" -C "$tmp_root/work" -p --json --session-id title-e2e 'design this change' >"$tmp_root/run.txt"
# the probe reports what core provides; no report means the fixture itself did not start - a failure
if [[ ! -f "$TITLE_CAPS" ]]; then
  printf 'session-title probe wrote no capability report (%s): the fixture did not start\n' "$TITLE_CAPS" >&2
  cat "$tmp_root/run.txt" >&2
  exit 1
fi
jq -e '.has_title_api == true' "$TITLE_CAPS" >/dev/null
jq -e '.name != null and (.name | length > 0) and .metadata.source == "provider"' "$TITLE_RESULT" >/dev/null
rg -q '"purpose":"title"' "$TITLE_CAPTURE"
: >"$TITLE_CAPTURE"
"$mare_bin" -C "$tmp_root/work" -p --resume title-e2e 'continue working' >"$tmp_root/resume.txt"
[[ ! -s "$TITLE_CAPTURE" ]]
"$mare_bin" -C "$tmp_root/work" -p --session-id title-manual --name 'Manual title' 'hello' >"$tmp_root/manual.txt"
jq -e '.name == "Manual title"' "$TITLE_RESULT" >/dev/null
[[ ! -s "$TITLE_CAPTURE" ]]
"$mare_bin" -C "$tmp_root/work" -p --no-session 'unsaved conversation' >"$tmp_root/unsaved.txt"
jq -e '.name == null' "$TITLE_RESULT" >/dev/null
[[ ! -s "$TITLE_CAPTURE" ]]
printf 'session-title file:// faux initial title, resume and manual-name precedence passed\n'

export TITLE_ALL=1
printf 'parser fixture\n' >"$tmp_root/work/title-input.txt"
printf '[{"tool_calls":[{"name":"read","arguments":{"path":"title-input.txt"}}]},{"text":"Stable parser title"},{"text":"Stable parser title"},{"text":"Stable parser title"},{"text":"Stable parser title"},{"text":"Stable parser title"},{"text":"Stable parser title"}]' >"$tmp_root/script.json"
python3 "$repo_root/tests/session-title-rpc.py" "$mare_bin" "$tmp_root/work"

had_skip=0
rc=0
python3 "$repo_root/tests/session-title-tui.py" "$mare_bin" "$tmp_root/work" || rc=$?
if [[ "$rc" -eq 77 ]]; then
  had_skip=1
elif [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

python3 "$repo_root/tests/session-title-errors.py" "$mare_bin" "$tmp_root/work"

python3 "$repo_root/tests/session-title-sources.py" "$mare_bin" "$tmp_root/work" "$tmp_root/script.json"
if [[ "$had_skip" -eq 1 ]]; then
  exit 77
fi
