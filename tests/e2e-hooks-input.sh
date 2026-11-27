#!/usr/bin/env bash
set -euo pipefail
if ! command -v rg >/dev/null 2>&1; then rg() { grep -E "$@"; }; fi
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
export MARE_BIN="$mare_bin"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-hooks-input.XXXXXX")"
trap 'if [[ "${KEEP_HOOK_TEST:-0}" == 1 ]]; then printf "hooks input fixture: %s\n" "$tmp_root"; else rm -rf "$tmp_root"; fi' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/hooks" "$repo_root/tests/fixtures/hooks-input-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" HOOK_INPUT_META="$tmp_root/work/meta.jsonl" HOOK_INPUT_REQUESTS="$tmp_root/work/requests.jsonl"
cat >"$tmp_root/work/input.py" <<'PY'
import json,os,sys,time
p=json.load(sys.stdin)
if p['hook_event_name']=='SessionStart':
    print('SESSION CONTEXT')
    sys.exit(0)
if p['hook_event_name']=='Stop':
    print(json.dumps({'decision':'block','reason':'GENERATED CONTINUATION'}) if not p['stop_hook_active'] else '{}')
    sys.exit(0)
assert p['hook_event_name']=='UserPromptSubmit'
with open('hooks.jsonl','a', encoding="utf-8") as f:f.write(json.dumps(p)+'\n')
mode=os.environ.get('HOOK_INPUT_MODE','context')
if os.path.exists('input.allow'):mode='context'
if mode=='wait':
    import signal
    with open('input.pid','w', encoding="utf-8") as f:f.write(str(os.getpid()))
    fifo=os.environ.get('HOOK_INPUT_FIFO')
    if fifo:
        fd=os.open(fifo,os.O_RDWR)
        os.write(fd,b'1')
        os.close(fd)
    signal.pause()
if mode=='timeout':time.sleep(2)
if mode=='deny' or mode=='queue' and 'DENY QUEUED' in p['prompt']:
    sys.stderr.write('INPUT BLOCKED')
    sys.exit(2)
if mode=='failure':
    sys.stderr.write('INPUT FAILURE')
    sys.exit(1)
if mode=='invalid':print('{broken')
elif mode=='structured':print(json.dumps({'hookSpecificOutput':{'hookEventName':'UserPromptSubmit','additionalContext':'STRUCTURED PROMPT CONTEXT'}}))
elif mode=='stop':print(json.dumps({'continue':False,'stopReason':'INPUT STOP REQUEST'}))
else:print('PROMPT CONTEXT: '+p['prompt'])
PY
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup {model="faux/echo",fallback_models={"faux/echo2"}}
local timeout=tonumber(mare.env("HOOK_INPUT_TIMEOUT")) or 10
local hooks={
 SessionStart={{hooks={{command="python3 input.py",timeout=timeout}}}},
 UserPromptSubmit={{matcher="[",hooks={{command="python3 input.py",timeout=timeout}}}},
}
if mare.env("HOOK_INPUT_STOP")=="1" then hooks.Stop={{hooks={{command="python3 input.py",timeout=timeout}}}} end
mare.plugins.add {{"test/hooks-input",url="file://$tmp_root/package",opts={hooks={sources={{
 dialect=mare.env("HOOK_DIALECT") or "codex",hooks=hooks
}}}}}}
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
rm -f "$MARE_HOME/state/log/mare.log"
doctor_out="$(HOOK_DIALECT=claude-code HOOK_INPUT_MODE=context "$mare_bin" -C "$tmp_root/work" doctor 2>&1 || true)"
if { cat "$MARE_HOME/state/log/mare.log" 2>/dev/null || true; printf '%s\n' "$doctor_out"; } | grep -Eq 'plugin hooks (failed|not started):.*requires agent\.capabilities|UserPromptSubmit skipped; core does not provide agent:capabilities'; then
    printf 'UserPromptSubmit unexpectedly skipped despite core agent:capabilities().input_admission\n' >&2
    exit 1
fi
printf '[{"error":"unknown model","kind":"model_not_found","retryable":false},{"tool_calls":[{"name":"hooks_input_probe","arguments":{}}]},{"text":"input done"},{"text":"continued input done"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
for dialect in claude-code codex; do
    export HOOK_DIALECT="$dialect"
    unset HOOK_INPUT_TIMEOUT
    for format in context structured; do
        export HOOK_INPUT_MODE="$format"
        rm -f "$HOOK_INPUT_META" "$HOOK_INPUT_REQUESTS" "$tmp_root/work/hooks.jsonl"
        "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'FINAL PROMPT' >"$tmp_root/$dialect-$format.jsonl"
        [[ "$(wc -l <"$HOOK_INPUT_META")" -eq 1 && "$(wc -l <"$tmp_root/work/hooks.jsonl")" -eq 1 ]]
        jq -s -e '.[0].prompt=="FINAL PROMPT"' "$tmp_root/work/hooks.jsonl" >/dev/null
        jq -s -e 'length==3 and all(.[];(.messages==.history) and ([.messages[]|select(.context_disclosure.namespace?=="hooks.prompts")]|length)==1 and ([.messages[]|select(.context_disclosure.namespace?=="hooks.lifecycle")]|length)==1 and (.system|contains("PROMPT CONTEXT")|not))' "$HOOK_INPUT_REQUESTS" >/dev/null
        rg -q 'INPUT TOOL EXECUTED' "$tmp_root/$dialect-$format.jsonl"
    done
    export HOOK_INPUT_MODE=context
    export HOOK_INPUT_STOP=1
    rm -f "$HOOK_INPUT_META" "$HOOK_INPUT_REQUESTS" "$tmp_root/work/hooks.jsonl"
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'STOP NOTIFICATION' >"$tmp_root/$dialect-generated.jsonl"
    [[ "$(wc -l <"$HOOK_INPUT_META")" -eq 1 && "$(wc -l <"$tmp_root/work/hooks.jsonl")" -eq 1 ]]
    [[ "$(wc -l <"$HOOK_INPUT_REQUESTS")" -eq 4 ]]
    rg -q 'GENERATED CONTINUATION' "$tmp_root/$dialect-generated.jsonl"
    unset HOOK_INPUT_STOP
    for mode in deny failure timeout invalid stop other-deny; do
        export HOOK_INPUT_MODE="$mode" HOOK_INPUT_TIMEOUT=0.5
        rm -f "$HOOK_INPUT_META" "$HOOK_INPUT_REQUESTS" "$tmp_root/work/hooks.jsonl"
        if "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'UNSENT ORIGINAL' >"$tmp_root/$dialect-$mode.jsonl"; then
            printf 'input refusal unexpectedly succeeded: %s %s\n' "$dialect" "$mode" >&2; exit 1
        fi
        [[ ! -e "$HOOK_INPUT_REQUESTS" ]]
        [[ "$(wc -l <"$HOOK_INPUT_META")" -eq 1 && "$(wc -l <"$tmp_root/work/hooks.jsonl")" -eq 1 ]]
        jq -s -e '[.[]|select(.type=="turn/completed")][0].data.not_sent==true' "$tmp_root/$dialect-$mode.jsonl" >/dev/null
    done
done
export HOOK_INPUT_WORK="$tmp_root/work"
unset HOOK_INPUT_TIMEOUT
had_skip=0
for driver in hooks-input-rpc.py hooks-input-ui.py; do
    rc=0
    python3 "$repo_root/tests/$driver" || rc=$?
    if [[ "$rc" -eq 77 ]]; then
        had_skip=1
    elif [[ "$rc" -ne 0 ]]; then
        exit "$rc"
    fi
done
for dialect in claude-code codex; do
    export HOOK_DIALECT="$dialect" HOOK_INPUT_MODE=mutate
    rm -f "$HOOK_INPUT_META" "$HOOK_INPUT_REQUESTS" "$tmp_root/work/hooks.jsonl"
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'FINAL PROMPT' >"$tmp_root/$dialect-mutate.jsonl"
    jq -s -e '.[0].content[0].text=="FINAL PROMPT"' "$HOOK_INPUT_META" >/dev/null
    jq -s -e '.[0].prompt=="FINAL PROMPT"' "$tmp_root/work/hooks.jsonl" >/dev/null
    [[ -s "$HOOK_INPUT_REQUESTS" ]]
    if rg -q 'CORRUPTED VOTER VIEW|corrupted-input|corrupted-generation' "$HOOK_INPUT_META" "$tmp_root/work/hooks.jsonl" "$HOOK_INPUT_REQUESTS"; then
        printf 'corrupted voter mutation leaked in %s mutate mode\n' "$dialect" >&2
        exit 1
    fi
done
if [[ "$had_skip" -eq 1 ]]; then
    exit 77
fi
printf 'hooks input: actual admission, source disclosure, veto/errors, fallback and tool-step once passed\n'
