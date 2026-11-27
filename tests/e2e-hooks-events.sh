#!/usr/bin/env bash
set -euo pipefail
if ! command -v rg >/dev/null 2>&1; then rg() { grep -E "$@"; }; fi
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
export MARE_BIN="$mare_bin"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-hooks-events.XXXXXX")"
trap 'if [[ "${KEEP_HOOK_TEST:-0}" == 1 ]]; then printf "hooks events fixture: %s\n" "$tmp_root"; else rm -rf "$tmp_root"; fi' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/hooks" "$repo_root/tests/fixtures/hooks-events-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" HOOK_REQUESTS="$tmp_root/work/requests.jsonl" HOOK_SESSION="$tmp_root/work/session.json"
cat >"$tmp_root/work/event.py" <<'PY'
import json, os, sys, time
p=json.load(sys.stdin)
with open('events.jsonl','a', encoding="utf-8") as f: f.write(json.dumps(p)+'\n')
if p['hook_event_name']=='SessionStart':
    assert 'turn_id' not in p
    mode=os.environ.get('HOOK_START_MODE','allow')
    if mode=='failure':
        print('UNSAFE NONZERO STDOUT')
        sys.stderr.write('SESSION START FAILURE')
        sys.exit(1)
    if mode=='timeout': time.sleep(2)
    if mode=='invalid': print('{broken')
    elif mode=='exit2-empty': sys.exit(2)
    else:
        print('START CONTEXT '+p['source'])
        cfifo=os.environ.get('HOOK_COMPACT_FIFO')
        if cfifo and p.get('source')=='compact':
            fd=os.open(cfifo,os.O_RDWR)
            os.write(fd,b'1')
            os.close(fd)
else:
    assert p['hook_event_name']=='Stop'
    assert isinstance(p['last_assistant_message'],str) and p['last_assistant_message']
    mode=os.environ.get('HOOK_STOP_MODE','continue')
    if mode=='failure':
        sys.stderr.write('STOP SCRIPT FAILURE')
        sys.exit(1)
    if mode=='timeout': time.sleep(2)
    if mode=='invalid':
        print('{broken')
        sys.exit(0)
    if mode=='exit2-empty': sys.exit(2)
    if mode=='exit2' and not p['stop_hook_active']:
        sys.stderr.write('EXIT TWO CONTINUE')
        sys.exit(2)
    if os.path.exists('allow-stop') or mode in ('allow','exit2'):
        print('{}')
    elif os.environ.get('HOOK_STOP_MODE')=='wait':
        import signal
        with open('stop.pid','w', encoding="utf-8") as f: f.write(str(os.getpid()))
        fifo=os.environ.get('HOOK_STOP_FIFO')
        if fifo:
            fd=os.open(fifo,os.O_RDWR)
            os.write(fd,b'1')
            os.close(fd)
        signal.pause()
    elif os.environ.get('HOOK_STOP_MODE')=='abort':
        print(json.dumps({'continue':False,'stopReason':'HOOK REQUESTED ABORT'}))
    elif not p['stop_hook_active']:
        print(json.dumps({'decision':'block','reason':'STOP CONTINUE'}))
    else: print('{}')
PY
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model="faux/echo" }
mare.plugin("compact",{auto=false,keep_recent_tokens=32,recent_user_tokens=32,stages={"local"}})
local dialect=mare.env("HOOK_DIALECT") or "codex"
local timeout=tonumber(mare.env("HOOK_EVENTS_TIMEOUT")) or 10
mare.plugins.add {{"test/hooks-events",url="file://$tmp_root/package",opts={hooks={sources={{dialect=dialect,hooks={
 SessionStart={{matcher="startup|resume|clear|compact",hooks={{command="python3 event.py",timeout=timeout}}}},
 Stop={{matcher="[",hooks={{command="python3 event.py",timeout=timeout}}}},
}}}}}}}
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"first answer"},{"text":"second answer"},{"text":"additional answer"},{"text":"additional answer"},{"text":"additional answer"},{"text":"additional answer"},{"text":"additional answer"},{"text":"short summary"},{"text":"after compact"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
export HOOK_START_MODE=allow
unset HOOK_EVENTS_TIMEOUT
for dialect in claude-code codex; do
    export HOOK_DIALECT="$dialect" HOOK_STOP_MODE=continue
    rm -f "$HOOK_REQUESTS" "$tmp_root/work/events.jsonl"
    start_rc=0
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id "hooks-$dialect" 'start hooks' >"$tmp_root/$dialect.jsonl" 2>"$tmp_root/$dialect.err" || start_rc=$?
    cat "$tmp_root/$dialect.err" >&2
    [[ "$start_rc" -eq 0 ]]
    if grep -q 'Stop hooks skipped: the core agent/turn-stopping event has no turn_id/cancel' "$MARE_HOME/state/log/mare.log" 2>/dev/null; then
        printf 'Stop hooks unexpectedly skipped despite core agent/turn-stopping turn_id/cancel\n' >&2
        exit 1
    fi
    jq -s -e '
      length==2 and all(.[]; ([.messages[]|select(.context_disclosure.namespace?=="hooks.lifecycle")]|length)==1 and
      (.messages==.history) and (.system|contains("START CONTEXT")|not)) and
      (.[1].messages|any(.content|tostring|contains("STOP CONTINUE")))
    ' "$HOOK_REQUESTS" >/dev/null
    jq -s -e '
      ([.[]|select(.hook_event_name=="SessionStart")]|length)==1 and
      ([.[]|select(.hook_event_name=="SessionStart")][0].transcript_path|type=="string" and length>0) and
      ([.[]|select(.hook_event_name=="Stop")]|map(.stop_hook_active))==[false,true]
    ' "$tmp_root/work/events.jsonl" >/dev/null
    session_id="$(jq -r .session_id "$HOOK_SESSION")"
    rm -f "$HOOK_REQUESTS"
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json -r "$session_id" 'resume hooks' >"$tmp_root/$dialect-resume.jsonl"
    jq -s -e 'length==2 and all(.[];([.messages[]|select(.context_disclosure.namespace?=="hooks.lifecycle")]|length)==2)' "$HOOK_REQUESTS" >/dev/null
    jq -s -e '[.[]|select(.hook_event_name=="SessionStart")|.source]==["startup","resume"]' "$tmp_root/work/events.jsonl" >/dev/null
    export HOOK_STOP_MODE=abort
    rm -f "$HOOK_REQUESTS"
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'abort from Stop' >"$tmp_root/$dialect-abort.jsonl" || true
    jq -s -e '[.[]|select(.type=="turn/completed")][0].data|.termination_reason=="interrupted"' "$tmp_root/$dialect-abort.jsonl" >/dev/null
    [[ "$(wc -l <"$HOOK_REQUESTS")" -eq 1 ]]
done
for dialect in claude-code codex; do
    export HOOK_DIALECT="$dialect" HOOK_EVENTS_TIMEOUT=0.5
    points=(start stop)
    for point in "${points[@]}"; do
        for fault in failure timeout invalid exit2-empty; do
            export HOOK_START_MODE=allow HOOK_STOP_MODE=allow
            if [[ "$point" == start ]]; then export HOOK_START_MODE="$fault"; else export HOOK_STOP_MODE="$fault"; fi
            rm -f "$HOOK_REQUESTS" "$tmp_root/work/events.jsonl"
            mkdir -p "$MARE_HOME/state/log"
            : >"$MARE_HOME/state/log/mare.log"
            "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'ordinary hook failure' >"$tmp_root/$dialect-$point-$fault.jsonl"
            jq -s -e '[.[]|select(.type=="turn/completed")][0].data|.termination_reason=="completed" and .text=="first answer" and .error==null' "$tmp_root/$dialect-$point-$fault.jsonl" >/dev/null
            [[ "$(wc -l <"$HOOK_REQUESTS")" -eq 1 ]]
            if [[ "$point" == start ]]; then diagnostic=SessionStart; else diagnostic=Stop; fi
            rg -q "$dialect $diagnostic 1:1" "$MARE_HOME/state/log/mare.log"
            if [[ "$point" == start ]]; then
                jq -s -e 'all(.[];[.messages[]|select(.context_disclosure.namespace?=="hooks.lifecycle")]|length==0) and (tostring|contains("UNSAFE NONZERO STDOUT")|not)' "$HOOK_REQUESTS" >/dev/null
            fi
        done
    done
    export HOOK_START_MODE=allow HOOK_STOP_MODE=exit2
    rm -f "$HOOK_REQUESTS"
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'exit two with feedback' >"$tmp_root/$dialect-exit2.jsonl"
    [[ "$(wc -l <"$HOOK_REQUESTS")" -eq 2 ]]
    rg -q 'EXIT TWO CONTINUE' "$tmp_root/$dialect-exit2.jsonl"
done
export HOOK_START_MODE=allow
unset HOOK_EVENTS_TIMEOUT
export HOOK_EVENTS_WORK="$tmp_root/work"
# both drivers run the codex dialect (regex matchers, mare.text.regex)
posix_driver_skipped=0
for driver in hooks-events-rpc.py hooks-events-ui.py; do
    rc=0
    python3 "$repo_root/tests/$driver" || rc=$?
    if [[ "$rc" -eq 77 ]]; then
        posix_driver_skipped=1
    elif [[ "$rc" -ne 0 ]]; then
        exit "$rc"
    fi
done
if [[ "$posix_driver_skipped" -eq 1 ]]; then
    exit 77
fi
printf 'hooks events: SessionStart source disclosure/resume and Stop continuation/active-reset/abort passed\n'
