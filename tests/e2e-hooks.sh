#!/usr/bin/env bash
set -euo pipefail
if ! command -v rg >/dev/null 2>&1; then rg() { grep -E "$@"; }; fi
# a "must not match" check: bash's set -e exempts a negated command, so `! rg -q ...` on its own
# line never stops the script - this one exits
refute_rg() { if rg -q "$@"; then printf 'unexpected match: rg -q %s\n' "$*" >&2; exit 1; fi; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
export MARE_BIN="$mare_bin"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-hooks-e2e.XXXXXX")"
host_tmp_root="$tmp_root"
if command -v cygpath >/dev/null 2>&1; then
  host_tmp_root="$(cygpath -m "$tmp_root")"
fi
trap 'if [[ "${KEEP_HOOK_TEST:-0}" == 1 ]]; then printf "hooks fixture: %s\n" "$tmp_root"; else rm -rf "$tmp_root"; fi' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/hooks" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/hooks-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" HOOK_SCRIPT="$tmp_root/work/check.py"
cat >"$HOOK_SCRIPT" <<'PY'
import errno, json, os, sys, time
raw = sys.stdin.buffer.read()
p = json.loads(raw)
mode = os.environ['HOOK_MODE']
post = mode.startswith('post-')
assert p['hook_event_name'] == ('PostToolUse' if post else 'PreToolUse')
assert p['transcript_path'] in ('', None)
assert p['tool_name'] == 'hooks_probe' and p['tool_input'] == {'value': 'executed' if post else 'actual'}
if post: assert p['tool_response']['content'] == 'PROBE EXECUTED executed'
assert raw.endswith(b'\n') == (os.environ['HOOK_DIALECT'] == 'claude-code')
mode = os.environ['HOOK_MODE']
if mode == 'sandbox':
    # This must fail inside read-only even though it is writable to the test owner.
    try:
        with open('FORBIDDEN', 'w', encoding="utf-8") as f: f.write('escaped')
    except OSError as error:
        assert error.errno in (errno.EACCES, errno.EPERM, errno.EROFS), repr(error)
        sys.stderr.write('SANDBOX_WRITE_REFUSED')
        sys.exit(2)
    sys.stderr.write('SANDBOX_WRITE_ESCAPED')
    sys.exit(1)
else:
    with open('invocations', 'a', encoding="utf-8") as f: f.write(p['tool_input']['value'] + '\n')
if mode in ('post-feedback', 'post-generic', 'post-error'):
    print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':'POST CONTEXT'}}))
elif mode == 'post-deny':
    print(json.dumps({'decision':'block','reason':'POST DENIED'}))
elif mode == 'post-timeout':
    time.sleep(3)
elif mode == 'post-failure':
    sys.exit(1)
elif mode == 'timeout':
    time.sleep(3)
elif mode == 'oversized':
    print('x' * (1024 * 1024 + 1))
elif mode == 'malformed':
    print('{broken')
elif mode == 'wrong-event':
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'Stop', 'permissionDecision': 'allow'}}))
elif mode == 'rewrite':
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'updatedInput': {'value': 'wrong'}}}))
elif mode == 'deny':
    sys.stderr.write('script denied')
    sys.exit(2)
elif mode == 'ask':
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'ask'}}))
else:
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'}}))
PY
cat >"$tmp_root/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 check.py","timeout":1}]}]}}
JSON
jq .hooks "$tmp_root/hooks.json" >"$tmp_root/bare.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
local dialect = mare.env("HOOK_DIALECT") or "claude-code"
local source = { dialect = dialect }
local variant = mare.env("HOOK_CONFIG_VARIANT")
if dialect == "codex" then
  source.path = "$host_tmp_root/hooks.json"
else
  source.hooks = { PreToolUse = { { matcher = "hooks_probe", hooks = {
    { type = "command", command = "python3 check.py", timeout = 1 }
  } } } }
end
if variant == "bare" then source.path = "$host_tmp_root/bare.json"; source.hooks = nil end
if variant == "alias" then source.hooks = { PreToolUse = { { hooks = { { command = "python3 check.py", timeoutSec = 1, description = "alias" } } } } }; source.path = nil end
-- matchers are Rust regex (mare.text.regex): "regex" matches hooks_probe,
-- "regex-miss" does not, "linear-regex" is the classic backtracking pattern (linear time here);
-- an invalid pattern and lookaround (unsupported) must fail startup
local patterns = {
  regex = "^hooks_pr[a-z]+$",
  ["regex-miss"] = "^nope_.*$",
  ["linear-regex"] = "^(a+)+$",
  invalid = "[",
  lookahead = "(?=hooks)hooks_probe",
  ["neg-lookahead"] = "^(?!hooks_)hooks_probe$",
}
if patterns[variant] then
  source.path = nil
  source.hooks = { PreToolUse = { { matcher = patterns[variant], hooks = { { command = "python3 check.py" } } } } }
end
local mode = mare.env("HOOK_MODE") or ""
if mode:match("^post%-") then source.path = nil; source.hooks = {PostToolUse={{matcher="hooks_probe",hooks={{command="python3 check.py",timeout=1}}}}} end
local options = { sources = { source }, defaultTimeoutMs = 1000, stderrSummaryMaxChars = 500 }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = options } } }
LUA
export HOOK_DIALECT=claude-code HOOK_MODE=allow
"$mare_bin" -C "$tmp_root/work" plugin sync
cat >"$tmp_root/script.json" <<'JSON'
[{"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},{"text":"done"}]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
for dialect in claude-code codex; do
  export HOOK_DIALECT="$dialect"
  for mode in allow deny rewrite ask other-deny sandbox retry malformed wrong-event timeout oversized; do
    export HOOK_MODE="$mode"
    rm -f "$tmp_root/work/invocations" "$tmp_root/work/FORBIDDEN" "$tmp_root/work/program-result-chain"
    if ! "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'validate a call' >"$tmp_root/$dialect-$mode.jsonl" 2>"$tmp_root/hooks.err"; then
      cat "$tmp_root/hooks.err" >&2
      exit 1
    fi
    if [[ "$mode" == allow || "$mode" == retry ]]; then
      jq -s -e 'tostring | contains("PROBE EXECUTED actual")' "$tmp_root/$dialect-$mode.jsonl" >/dev/null
      # the probe's tool/program-result listener (result, call, operation, next) ran on and the
      # chain after it returned, once for the one execution
      [[ "$(wc -l <"$tmp_root/work/program-result-chain")" -eq 1 ]]
      jq -e '.execution_id != null and .value == "actual" and .returned' "$tmp_root/work/program-result-chain" >/dev/null
    else
      jq -s -e 'tostring | contains("PROBE EXECUTED actual") | not' "$tmp_root/$dialect-$mode.jsonl" >/dev/null
    fi
    case "$mode" in
      retry) [[ "$(wc -l <"$tmp_root/work/invocations")" -eq 2 ]] ;;
      sandbox) [[ ! -e "$tmp_root/work/FORBIDDEN" ]]; jq -s -e 'tostring | contains("SANDBOX_WRITE_REFUSED")' "$tmp_root/$dialect-$mode.jsonl" >/dev/null ;;
      rewrite) jq -s -e 'tostring | contains("updatedInput")' "$tmp_root/$dialect-$mode.jsonl" >/dev/null ;;
      deny) jq -s -e 'tostring | contains("script denied")' "$tmp_root/$dialect-$mode.jsonl" >/dev/null ;;
      other-deny) jq -s -e 'tostring | contains("independent policy denied")' "$tmp_root/$dialect-$mode.jsonl" >/dev/null ;;
    esac
  done
done
export HOOK_DIALECT=codex HOOK_MODE=allow
for variant in bare alias regex; do
  export HOOK_CONFIG_VARIANT="$variant"
  rm -f "$tmp_root/work/invocations"
  "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'validate configured call' >"$tmp_root/config-$variant.jsonl"
  jq -s -e 'tostring | contains("PROBE EXECUTED actual")' "$tmp_root/config-$variant.jsonl" >/dev/null
  [[ "$(wc -l <"$tmp_root/work/invocations")" -eq 1 ]]
done
# a regex that does not match: the (deny) hook never runs, the call goes ahead
export HOOK_CONFIG_VARIANT="regex-miss" HOOK_MODE=deny
rm -f "$tmp_root/work/invocations"
"$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'regex miss' >"$tmp_root/config-regex-miss.jsonl"
jq -s -e 'tostring | contains("PROBE EXECUTED actual")' "$tmp_root/config-regex-miss.jsonl" >/dev/null
[[ ! -e "$tmp_root/work/invocations" ]]
# the classic backtracking pattern against a long tool name: linear time, no match, no hook
mkdir -p "$MARE_HOME/config/plugins"
cat >"$MARE_HOME/config/plugins/backtrack-probe.lua" <<'LUA'
return {
  name = "backtrack-probe",
  inject = { "tools" },
  apply = function(ctx)
    ctx.tools:register("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_x", {
      description = "backtrack probe tool",
      parameters = { type = "object", properties = {} },
      side_effect = "read",
      execute = function()
        return { content = "BACKTRACK PROBE EXECUTED" }
      end,
    })
  end,
}
LUA
printf '[{"tool_calls":[{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_x","arguments":{}}]},{"text":"done"}]' >"$tmp_root/backtrack-script.json"
export HOOK_CONFIG_VARIANT="linear-regex" HOOK_MODE=allow MARE_FAUX_SCRIPT="$tmp_root/backtrack-script.json"
rm -f "$tmp_root/work/invocations"
timeout 60 "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'linear regex' >"$tmp_root/config-linear-regex.jsonl"
jq -s -e 'tostring | contains("BACKTRACK PROBE EXECUTED")' "$tmp_root/config-linear-regex.jsonl" >/dev/null
[[ ! -e "$tmp_root/work/invocations" ]]
rm -f "$MARE_HOME/config/plugins/backtrack-probe.lua"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
for variant in invalid lookahead neg-lookahead; do
  export HOOK_CONFIG_VARIANT="$variant"
  if "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'invalid configured call' >"$tmp_root/config-$variant.jsonl" 2>"$tmp_root/config-$variant.stderr"; then
    printf 'invalid matcher silently accepted: %s\n' "$variant" >&2; exit 1
  fi
  refute_rg 'PROBE EXECUTED' "$tmp_root/config-$variant.jsonl"
  # the startup failure names the unsupported matcher
  cat "$tmp_root/config-$variant.jsonl" "$tmp_root/config-$variant.stderr" | rg -q 'is not a supported regex' || {
    printf 'no clear matcher error for %s\n' "$variant" >&2; cat "$tmp_root/config-$variant.stderr" >&2; exit 1
  }
done
unset HOOK_CONFIG_VARIANT
for dialect in claude-code codex; do
  export HOOK_DIALECT="$dialect"
  for mode in post-feedback post-deny post-failure post-timeout post-error post-generic; do
    export HOOK_MODE="$mode"
    rm -f "$tmp_root/work/invocations" "$tmp_root/work/after-chain"
    if [[ "$dialect" == claude-code && "$mode" == post-feedback ]]; then
      rm -f "$MARE_HOME/state/log/mare.log"
    fi
    "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'execute and process the result' >"$tmp_root/$dialect-$mode.jsonl" 2>"$tmp_root/$dialect-$mode.err"
    if [[ "$dialect" == claude-code && "$mode" == post-feedback ]] && rg -q 'PostToolUse skipped; core does not provide' "$MARE_HOME/state/log/mare.log" "$tmp_root/$dialect-$mode.err" 2>/dev/null; then
      printf 'PostToolUse unexpectedly skipped despite core result_pipeline support\n' >&2
      exit 1
    fi
    [[ "$(wc -l <"$tmp_root/work/invocations")" -eq 1 ]]
    [[ "$(wc -l <"$tmp_root/work/after-chain")" -eq 1 ]]
    jq -e '.execution_id != null and .value == "executed"' "$tmp_root/work/after-chain" >/dev/null
    jq -s -e '[.[] | select(.type == "item/completed" and .data.item.type == "tool_call")][0].data.item | .name == "hooks_probe" and .arguments.value == "actual"' "$tmp_root/$dialect-$mode.jsonl" >/dev/null
    if [[ "$mode" == post-generic ]]; then
      rg -q 'GENERIC REPLACEMENT' "$tmp_root/$dialect-$mode.jsonl"
    else rg -q 'PROBE EXECUTED executed' "$tmp_root/$dialect-$mode.jsonl"; fi
    if [[ "$mode" == post-deny || "$mode" == post-failure || "$mode" == post-timeout || "$mode" == post-error ]]; then
      jq -s -e '[.[] | select(.type == "item/completed" and .data.item.type == "tool_call")][0].data.item.result.is_error == true' "$tmp_root/$dialect-$mode.jsonl" >/dev/null
    fi
    case "$mode" in
      post-feedback|post-generic|post-error) rg -q 'POST CONTEXT' "$tmp_root/$dialect-$mode.jsonl" ;;
      post-deny) rg -q 'POST DENIED' "$tmp_root/$dialect-$mode.jsonl" ;;
      post-timeout) rg -q 'hook timed out, cancelled or signalled' "$tmp_root/$dialect-$mode.jsonl" ;;
      post-failure) rg -q 'hook failed with exit code 1' "$tmp_root/$dialect-$mode.jsonl" ;;
    esac
  done
done
for dialect in claude-code codex; do
  export HOOK_DIALECT="$dialect" HOOK_MODE=post-refused
  rm -f "$tmp_root/work/invocations" "$tmp_root/work/after-chain"
  "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session --json 'refuse before execution' >"$tmp_root/$dialect-post-refused.jsonl"
  [[ ! -e "$tmp_root/work/invocations" && ! -e "$tmp_root/work/after-chain" ]]
done
printf 'mare-plugins: hooks file:// faux policies, current sandbox write refusal and real core retry passed\n'
