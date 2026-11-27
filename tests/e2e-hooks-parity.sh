#!/usr/bin/env bash
set -euo pipefail
if ! command -v rg >/dev/null 2>&1; then rg() { grep -E "$@"; }; fi
# a "must not match" check: bash's set -e exempts a negated command, so `! rg -q ...` on its own
# line never stops the script - this one exits
refute_rg() { if rg -q "$@"; then printf 'unexpected match: rg -q %s\n' "$*" >&2; exit 1; fi; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export MARE_PLUGINS_PTY="$repo_root/tests/pty" # Vendored Python PTY harness.
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
export MARE_BIN="$mare_bin"
builtin_plugins_dir="$("$mare_bin" runtime | tail -n1)/plugins"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-hooks-parity.XXXXXX")"
tmp_root="$(cd -- "$tmp_root" && pwd -P)"
host_tmp_root="$tmp_root"
if command -v cygpath >/dev/null 2>&1; then
  host_tmp_root="$(cygpath -m "$tmp_root")"
fi
disc_home=""
trap 'if [[ "${KEEP_HOOK_TEST:-0}" == 1 ]]; then printf "hooks parity fixture: %s %s\n" "$tmp_root" "$disc_home"; else rm -rf "$tmp_root" ${disc_home:+"$disc_home"}; fi' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work/plugin-root"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/hooks" "$repo_root/tests/fixtures/hooks-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home"

cat >"$tmp_root/work/plugin-root/run.py" <<'PY'
import json, os, sys
p = json.load(sys.stdin)
with open(os.environ['PARITY_LOG'], 'a', encoding="utf-8") as f:
    f.write(json.dumps({'argv': sys.argv[1:], 'event': p['hook_event_name'], 'p': p}) + '\n')
mode = os.environ.get('PARITY_MODE', 'allow')
ev = p['hook_event_name']
if ev == 'PreToolUse':
    if mode.startswith('perm-'):
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'ask'}}))
    elif mode == 'slow-allow':
        import time
        time.sleep(1.5)
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'}}))
    elif mode == 'sysmsg':
        print(json.dumps({'systemMessage': 'VISIBLE NOTICE', 'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'}}))
    elif mode == 'suppressed':
        print(json.dumps({'systemMessage': 'HIDDEN NOTICE', 'suppressOutput': True, 'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'}}))
    else:
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'}}))
elif ev == 'PermissionRequest':
    if mode == 'perm-allow':
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}))
    elif mode == 'perm-deny':
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'PERM DENIED'}}}))
    elif mode == 'perm-invalid':
        print('{broken')
    elif mode == 'perm-error':
        sys.stderr.write('PERM ERROR')
        sys.exit(1)
    elif mode == 'perm-timeout':
        import time
        time.sleep(10)
    else:
        print('{}')
elif ev == 'SessionEnd':
    if mode == 'session-end-fail':
        sys.stderr.write('SESSION END ERR')
        sys.exit(1)
    if mode == 'session-end-slow':
        import select
        tag = sys.argv[1]
        other = 'slow2' if tag == 'slow1' else 'slow1'
        gate_dir = os.environ['PARITY_GATE_DIR']
        fd_out = os.open(os.path.join(gate_dir, f'{tag}.fifo'), os.O_RDWR)
        fd_in = os.open(os.path.join(gate_dir, f'{other}.fifo'), os.O_RDWR)
        os.write(fd_out, b'1')
        ready, _, _ = select.select([fd_in], [], [], 2.5)
        if not ready:
            sys.stderr.write(f'{tag} timed out waiting for {other}')
            sys.exit(1)
        os.read(fd_in, 1)
        os.close(fd_out)
        os.close(fd_in)
        open(os.path.join(gate_dir, f'{tag}.released'), 'w', encoding="utf-8").close()
    print('{}')
elif ev == 'PreCompact':
    if os.path.exists('pre-stop'):
        print(json.dumps({'continue': False, 'stopReason': 'PRE STOPPED'}))
    elif os.path.exists('pre-block'):
        print(json.dumps({'decision': 'block', 'reason': 'PRE BLOCKED'}))
    elif mode == 'compact-veto' and not os.path.exists('allow-compact'):
        sys.stderr.write('COMPACT VETOED')
        sys.exit(2)
    else:
        print('{}')
elif ev == 'PostCompact':
    if os.path.exists('post-stop'):
        print(json.dumps({'continue': False, 'stopReason': 'POST STOPPED'}))
    else:
        print('{}')
    pfifo = os.environ.get('PARITY_POST_COMPACT_FIFO')
    if pfifo:
        fd = os.open(pfifo, os.O_RDWR)
        os.write(fd, b'1')
        os.close(fd)
else:
    print('{}')
PY

cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  sources = {
    {
      dialect = "claude-code",
      plugin_root = "$host_tmp_root/work/plugin-root",
      hooks = {
        PreToolUse = {
          { matcher = "hooks_probe", hooks = {
            { type = "prompt", prompt = "ignored" },
            { type = "command", command = "'python3' '\${CLAUDE_PLUGIN_ROOT}/run.py' '\${CLAUDE_PLUGIN_ROOT}' '\${CLAUDE_PROJECT_DIR}'", commandWindows = "python3 '\${CLAUDE_PLUGIN_ROOT}/run.py' '\${CLAUDE_PLUGIN_ROOT}' '\${CLAUDE_PROJECT_DIR}'", timeout = 700 },
          } },
        },
        PermissionRequest = {
          { matcher = "hooks_probe", hooks = {
            { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 2 },
          } },
        },
        SessionEnd = {
          { matcher = "other", hooks = {
            { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 10, async = true },
          } },
        },
      },
    },
  },
} } } }
LUA

"$mare_bin" -C "$tmp_root/work" plugin sync
cat >"$tmp_root/script.json" <<'JSON'
[{"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},{"text":"done"}]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
export PARITY_LOG="$tmp_root/work/parity.jsonl"
export HOOK_MODE="allow"

# 1. PermissionRequest allow + placeholder substitution + SessionEnd + warnings
export PARITY_MODE="perm-allow"
rm -f "$PARITY_LOG"
mkdir -p "$MARE_HOME/state/log"
: >"$MARE_HOME/state/log/mare.log"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/perm-allow.jsonl"
rg -q 'PROBE EXECUTED actual' "$tmp_root/perm-allow.jsonl"
jq -s -e '
  (([.[] | select(.event == "PreToolUse")][0].argv | map(gsub("\\\\"; "/"))) == ["'"$host_tmp_root/work/plugin-root"'", "'"$host_tmp_root/work"'"]) and
  # Core approvals.request may rerun the mandatory policy check after an allow, so tool/approval
  # voters, including this hook, run once or twice.
  ([.[] | select(.event == "PermissionRequest")] | (length == 1 or length == 2) and (map(.p.tool_input) | unique | length == 1)) and
  ([.[] | select(.event == "SessionEnd")][0].p.reason == "other")
' "$PARITY_LOG" >/dev/null
rg -q 'skipping unsupported "prompt" hook' "$MARE_HOME/state/log/mare.log"
rg -q 'running async SessionEnd hook synchronously' "$MARE_HOME/state/log/mare.log"
rg -q 'clamping SessionEnd timeout to 3s' "$MARE_HOME/state/log/mare.log"

# 1b. A sync PreToolUse hook is bounded by its own command timeout, not by the core's default
# policy voter timeout: with policy_timeout_ms lowered to 500 ms, a hook that answers allow after
# 1.5 s (its own timeout is 700 s) still lets the tool run.
export PARITY_MODE="slow-allow"
rm -f "$PARITY_LOG"
"$mare_bin" -C "$tmp_root/work" --yolo --set policy_timeout_ms=500 -p --json --no-session 'run probe' >"$tmp_root/slow-allow.jsonl"
rg -q 'PROBE EXECUTED actual' "$tmp_root/slow-allow.jsonl"
jq -s -e '[.[] | select(.event == "PreToolUse")] | length >= 1' "$PARITY_LOG" >/dev/null

# 2. PermissionRequest deny
export PARITY_MODE="perm-deny"
rm -f "$PARITY_LOG"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/perm-deny.jsonl" || true
rg -q 'PERM DENIED' "$tmp_root/perm-deny.jsonl"
refute_rg 'PROBE EXECUTED' "$tmp_root/perm-deny.jsonl"

# 3. PermissionRequest undecided ({}) abstains and headless fails closed (no human/RPC/TUI approver)
mkdir -p "$MARE_HOME/config/plugins"
cat >"$MARE_HOME/config/plugins/ask-probe.lua" <<'LUA'
return {
  name = "ask-probe",
  inject = { "policy" },
  apply = function(ctx)
    ctx.policy:voter("tool/before", function(call)
      if call.name == "hooks_probe" then
        return { decision = "ask", reason = "needs approval" }
      end
    end)
  end,
}
LUA
export PARITY_MODE="perm-empty"
rm -f "$PARITY_LOG"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/perm-empty.jsonl" || true
rg -q 'approval (was )?required but nobody can answer|nobody approved the request' "$tmp_root/perm-empty.jsonl"
refute_rg 'PROBE EXECUTED' "$tmp_root/perm-empty.jsonl"
rm -f "$MARE_HOME/config/plugins/ask-probe.lua"

# 4. SessionEnd failure is diagnostic-only and does not fail exit
export PARITY_MODE="session-end-fail"
rm -f "$PARITY_LOG"
: >"$MARE_HOME/state/log/mare.log"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/session-end-fail.jsonl"
rg -q 'SESSION END ERR' "$MARE_HOME/state/log/mare.log"

# 5. systemMessage and suppressOutput
export PARITY_MODE="sysmsg"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/sysmsg.jsonl" 2>"$tmp_root/sysmsg.err"
rg -q 'PROBE EXECUTED actual' "$tmp_root/sysmsg.jsonl"
rg -q 'VISIBLE NOTICE' "$tmp_root/sysmsg.err"

export PARITY_MODE="suppressed"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/suppressed.jsonl" 2>"$tmp_root/suppressed.err"
rg -q 'PROBE EXECUTED actual' "$tmp_root/suppressed.jsonl"
refute_rg 'HIDDEN NOTICE' "$tmp_root/suppressed.err"
refute_rg 'HIDDEN NOTICE' "$tmp_root/suppressed.jsonl"

# 6. legacy notify argv adapter (payload JSON as last argv, stdin null) + tool-alias dedup (Read + read)
cat >"$tmp_root/work/plugin-root/legacy_notify.py" <<'PY'
import json, os, sys
stdin_data = sys.stdin.read()
payload = json.loads(sys.argv[-1])
with open(os.environ['NOTIFY_LOG'], 'a', encoding="utf-8") as f:
    f.write(json.dumps({'stdin_empty': stdin_data == '', 'event': payload['hook_event_name'], 'argv_len': len(sys.argv)}) + '\n')
PY
printf 'hello\n' >"$tmp_root/work/sample.txt"
cat >"$tmp_root/dedup-script.json" <<'JSON'
[{"tool_calls":[{"name":"read","arguments":{"path":"sample.txt"}}]},{"text":"done"}]
JSON
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  sources = {
    {
      dialect = "codex",
      notify = { "python3", "$host_tmp_root/work/plugin-root/legacy_notify.py" },
    },
    {
      dialect = "claude-code",
      hooks = {
        PreToolUse = {
          { matcher = "Read", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 2 } } },
          { matcher = "read", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 2 } } },
        },
      },
    },
  },
} } } }
LUA
export MARE_FAUX_SCRIPT="$tmp_root/dedup-script.json"
export PARITY_MODE="allow"
export NOTIFY_LOG="$tmp_root/work/legacy-notify.jsonl"
rm -f "$PARITY_LOG" "$NOTIFY_LOG"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'dedup and legacy notify' >"$tmp_root/dedup.jsonl"
jq -s -e '([.[] | select(.event == "PreToolUse")] | length) == 1' "$PARITY_LOG" >/dev/null
jq -s -e 'length == 1 and .[0].stdin_empty == true and .[0].event == "Stop"' "$NOTIFY_LOG" >/dev/null

# 7. Headless requireTrust fail-closed + RPC PreCompact/PostCompact/trust ui.select/slash command
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugin("compact", { auto = false, keep_recent_tokens = 32, recent_user_tokens = 32, stages = { "local" } })
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  requireTrust = true,
  sources = {
    {
      dialect = "codex",
      hooks = {
        PreToolUse = {
          { matcher = "hooks_probe", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
        PreCompact = {
          { matcher = "manual", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
        PostCompact = {
          { matcher = "manual", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
      },
    },
  },
} } } }
LUA
cat >"$tmp_root/rpc-script.json" <<'JSON'
[
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"1"}}]},
  {"text":"first"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"2"}}]},
  {"text":"second"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"3"}}]},
  {"text":"third"},
  {"text":"compact1"},
  {"text":"compact2"},
  {"text":"compact3"},
  {"text":"compact4"},
  {"text":"summary"},
  {"text":"after pre-stop"},
  {"text":"after post-stop 0"},
  {"text":"after post-stop 1"},
  {"text":"after post-stop 2"},
  {"text":"after post-stop 3"},
  {"text":"summary2"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/rpc-script.json"
rm -f "$PARITY_LOG"
untrusted_rc=0
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'untrusted headless' >"$tmp_root/untrusted.jsonl" || untrusted_rc=$?
export PARITY_RPC_WORK="$tmp_root/work" # later sections drive the same work dir over RPC
# sections 7 (rest), 8 and 9 use regex matchers (mare.text.regex, always available)
rg -q 'untrusted or modified hook handler' "$tmp_root/untrusted.jsonl"
refute_rg 'PROBE EXECUTED' "$tmp_root/untrusted.jsonl"

export PARITY_RPC_WORK="$tmp_root/work"
had_skip=0
rc=0
python3 "$repo_root/tests/hooks-parity-rpc.py" || rc=$?
if [[ "$rc" -eq 77 ]]; then
  had_skip=1
elif [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

# 8. Compact failure, cancel, and auto-compaction PostCompact continue:false
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
-- the threshold (10% of faux/echo's 100k window) sits above core's fixed system+tools overhead
-- (roughly 4.4k tokens) so a summary fits; the 8000-word second prompt crosses it.
mare.plugin("compact", { auto = true, threshold_ratio = 0.1, keep_recent_tokens = 32, recent_user_tokens = 32, stages = { "local" } })
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  sources = {
    {
      dialect = "codex",
      hooks = {
        PreCompact = {
          { matcher = "auto|manual", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
        PostCompact = {
          { matcher = "auto|manual", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
      },
    },
  },
} } } }
LUA
cat >"$tmp_root/auto-compact-script.json" <<'JSON'
[
  {"text":"first reply with enough tokens to help push the conversation over the auto compaction threshold"},
  {"text":"second reply with enough tokens to help push the conversation over the auto compaction threshold"},
  {"text":"auto compact summary"},
  {"text":"should never reach this turn"},
  {"text":"slow summary", "delay_ms": 5000}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/auto-compact-script.json"
python3 - <<'PY'
import importlib.util, json, os, pathlib, sys, time
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "compact-m7.jsonl"
log_path.unlink(missing_ok=True)

# (a) Failure on empty session: PreCompact runs, PostCompact must NOT run.
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="allow")
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    fail_res = client.call("compact.run", {"session_id": sid})
    assert fail_res.get("status") == "nothing_to_compact", fail_res
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert [e["event"] for e in events] == ["PreCompact"], events
finally:
    client.call("shutdown")
    client.p.wait(timeout=10)

# (b) Auto compaction: PreCompact exit 2 does NOT block, PostCompact continue:false aborts the turn.
log_path.unlink(missing_ok=True)
(work / "post-stop").write_text("1", encoding="utf-8")
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="compact-veto")
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    s1 = client.call("agent.prompt", {"session_id": sid, "input": "first prompt " + ("word " * 30)})
    client.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})
    started = client.call("agent.prompt", {"session_id": sid, "input": "second prompt triggers auto compact " + ("word " * 8000)})
    end = None
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        for ev in client.events:
            if ev.get("type") == "turn/completed" and ev.get("turn_id") == started["turn_id"]:
                end = ev
                break
        if end:
            break
        client.dispatch(client.read())
    assert end is not None, client.events
    data = end["data"]
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert [e["event"] for e in events] == ["PreCompact", "PostCompact"], events
    assert events[0]["p"]["trigger"] == "auto" and events[1]["p"]["trigger"] == "auto", events
    # compact/after is emit (return value ignored): PostCompact ran and the turn completes
    assert data["termination_reason"] == "completed", (data, [e for e in client.events if e.get("type", "").startswith("compact")])
finally:
    (work / "post-stop").unlink(missing_ok=True)
    client.call("shutdown")
    client.p.wait(timeout=10)
PY

# (c) Cancelled compaction: PostCompact must NOT run when compaction is aborted mid-flight.
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugin("compact", { auto = false, keep_recent_tokens = 32, recent_user_tokens = 32, stages = { "local" } })
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  sources = {
    {
      dialect = "codex",
      hooks = {
        PreCompact = {
          { matcher = "manual", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
        PostCompact = {
          { matcher = "manual", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 5 } } },
        },
      },
    },
  },
} } } }
LUA
cat >"$tmp_root/cancel-compact-script.json" <<'JSON'
[
  {"text":"turn 1"},
  {"text":"turn 2"},
  {"text":"turn 3"},
  {"text":"turn 4"},
  {"text":"slow summary", "delay_ms": 5000}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/cancel-compact-script.json"
python3 - <<'PY'
import importlib.util, json, os, pathlib, subprocess, threading, time
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

def wait_for_event(client, kind, timeout=5):
    watchdog = threading.Timer(timeout, client.p.kill)
    watchdog.start()
    try:
        while not any(ev.get("type") == kind for ev in client.events):
            try:
                client.dispatch(client.read())
            except RuntimeError:
                raise AssertionError(f"timed out waiting for {kind}: {client.events}")
    finally:
        watchdog.cancel()

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "compact-cancel.jsonl"
log_path.unlink(missing_ok=True)
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="allow")
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    for i in range(4):
        s = client.call("agent.prompt", {"session_id": sid, "input": f"turn {i}"})
        client.call("agent.wait", {"session_id": sid, "turn_id": s["turn_id"]})
    res = client.call("commands.run", {"line": "/compact"})
    assert isinstance(res, dict), res
    wait_for_event(client, "compact/started", 5)
    # New session aborts any in-flight compaction via session/store.lua compact:abort().
    client.call("commands.run", {"line": "/new"})
    wait_for_event(client, "compact/completed", 5)
    end_ev = [ev for ev in client.events if ev.get("type") == "compact/completed"][-1]
    assert end_ev["data"].get("status") == "cancelled" or end_ev["data"].get("cancelled") is True, end_ev
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert [e["event"] for e in events] == ["PreCompact"], events
finally:
    client.call("shutdown")
    client.p.wait(timeout=10)
PY

# 9. SessionEnd: /new old session_id + flushed transcript_path, once per end, no child session, concurrent slow hooks
mkdir -p "$MARE_HOME/config/plugins"
cat >"$MARE_HOME/config/plugins/child-probe.lua" <<'LUA'
return {
  name = "child-probe",
  inject = { "commands", "session" },
  apply = function(ctx)
    if ctx.commands then
      ctx.commands:register("spawn-child", {
        description = "spawn a child subagent",
        run = function()
          local a = mare.subagent.start({ prompt = "child turn", cwd = mare.cwd })
          a:wait()
        end,
      })
      ctx.commands:register("switch-new", {
        description = "retire active session in place and start a new session",
        run = function()
          if ctx.session.switch then
            ctx.session:switch({ kind = "new" })
          else
            ctx.session:create()
          end
        end,
      })
    end
  end,
}
LUA
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add {
  { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
    sources = {
      {
        dialect = "codex",
        hooks = {
          SessionEnd = {
            { matcher = "clear|other", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py' single", timeout = 3 } } },
          },
        },
      },
    },
  } } },
}
LUA
cat >"$tmp_root/session-end-script.json" <<'JSON'
[
  {"text":"old session reply"},
  {"text":"child session reply"},
  {"text":"new session reply"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/session-end-script.json"
python3 - <<'PY'
import importlib.util, json, os, pathlib, time
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "session-end-m6.jsonl"
log_path.unlink(missing_ok=True)
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="allow")
old_id = "old-session-0001"
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--yolo", "--session-id", old_id], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    s1 = client.call("agent.prompt", {"session_id": sid, "input": "hello old session"})
    client.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})

    # Subagent/child session must NOT trigger SessionEnd.
    res = client.call("commands.run", {"line": "/spawn-child"})
    assert isinstance(res, dict), res
    assert not log_path.exists() or log_path.read_text(encoding="utf-8").strip() == "", log_path.read_text(encoding="utf-8")

    # Retiring the active session into a new session must fire SessionEnd ONCE with old session_id and flushed old transcript_path.
    client.call("commands.run", {"line": "/switch-new"})
    new_id = client.call("status.get", {})["session"]["session_id"]
    assert new_id != old_id, (old_id, new_id)
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len(events) == 1, events
    ev = events[0]
    assert ev["event"] == "SessionEnd", ev
    assert ev["p"]["reason"] == "clear", ev
    assert ev["p"]["session_id"] == old_id, (ev, old_id)
    tp = pathlib.Path(ev["p"]["transcript_path"])
    assert tp.exists(), tp
    tp_text = tp.read_text(encoding="utf-8")
    assert "hello old session" in tp_text and "old session reply" in tp_text, tp_text

    # Turn in new session, then shutdown -> SessionEnd fires ONCE more for new session with reason=other.
    s2 = client.call("agent.prompt", {"session_id": new_id, "input": "hello new session"})
    client.call("agent.wait", {"session_id": new_id, "turn_id": s2["turn_id"]})
finally:
    client.call("shutdown")
    client.p.wait(timeout=10)

events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
assert len(events) == 2, events
assert events[1]["p"]["reason"] == "other" and events[1]["p"]["session_id"] == new_id, (events, new_id)
PY

# Two slow SessionEnd hooks (1.2s each) must run concurrently within the 3000ms window.
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add {
  { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
    sources = {
      {
        dialect = "codex",
        hooks = {
          SessionEnd = {
            { matcher = "clear|other", hooks = {
              { command = "python3 '$host_tmp_root/work/plugin-root/run.py' slow1", timeout = 2 },
              { command = "python3 '$host_tmp_root/work/plugin-root/run.py' slow2", timeout = 2 },
            } },
          },
        },
      },
    },
  } } },
}
LUA
rc=0
python3 - <<'PY' || rc=$?
import os, sys
if not hasattr(os, "mkfifo"):
    print("SKIPPED[capability=posix.fifo] POSIX FIFO driver")
    sys.exit(77)
import importlib.util, json, pathlib, time
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "session-end-slow.jsonl"
log_path.unlink(missing_ok=True)
gate_dir = work / "session-end-gate"
gate_dir.mkdir(exist_ok=True)
for f in gate_dir.iterdir():
    f.unlink()
os.mkfifo(gate_dir / "slow1.fifo")
os.mkfifo(gate_dir / "slow2.fifo")
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="session-end-slow", PARITY_GATE_DIR=str(gate_dir))
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--yolo"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    s1 = client.call("agent.prompt", {"session_id": sid, "input": "slow end test"})
    client.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})
    client.call("commands.run", {"line": "/switch-new"})
    events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert sorted(e["argv"][0] for e in events) == ["slow1", "slow2"], events
    assert (gate_dir / "slow1.released").exists() and (gate_dir / "slow2.released").exists(), list(gate_dir.iterdir())
finally:
    client.call("shutdown")
    client.p.wait(timeout=10)
PY
if [[ "$rc" -eq 77 ]]; then
  had_skip=1
elif [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi


# 10. PermissionRequest tri-state: abstain -> RPC/TUI approve, deny wins, fail-closed on timeout/error/invalid, tool/before deny, protected_arguments.
rm -f "$MARE_HOME/config/plugins/child-probe.lua"
mkdir -p "$MARE_HOME/config/plugins"
cat >"$MARE_HOME/config/plugins/ask-probe.lua" <<'LUA'
return {
  name = "ask-probe",
  inject = { "policy" },
  apply = function(ctx)
    ctx.policy:voter("tool/before", function(call)
      if call.name == "hooks_probe" then
        return { decision = "ask", reason = "needs approval" }
      end
    end)
  end,
}
LUA
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  sources = {
    {
      dialect = "claude-code",
      hooks = {
        PermissionRequest = {
          { matcher = "hooks_probe|hidden_probe", hooks = { { command = "python3 '$host_tmp_root/work/plugin-root/run.py'", timeout = 0.5 } } },
        },
      },
    },
  },
} } } }
LUA
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
python3 - <<'PY'
import importlib.util, json, os, pathlib
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "perm-m2.jsonl"

# (a) Empty/unmatched PermissionRequest abstains -> RPC client approves -> ALLOWED.
log_path.unlink(missing_ok=True)
env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE="perm-empty")
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0", "capabilities": {"approvals": True}})["session"]["session_id"]
    client.on_approval = lambda p: "allow"
    s1 = client.call("agent.prompt", {"session_id": sid, "input": "run probe"})
    res = client.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})
    assert len(client.approvals) == 1, (client.approvals, client.events)
    assert any(
        ev.get("type") == "item/completed"
        and (ev.get("data") or {}).get("item", {}).get("type") == "tool_call"
        and "PROBE EXECUTED actual" in json.dumps(ev)
        for ev in client.events
    ), client.events
finally:
    client.call("shutdown")
    client.p.wait(timeout=10)

# (d) PermissionRequest timeout / error / malformed JSON -> DENIED even if RPC client would allow.
for mode in ("perm-timeout", "perm-error", "perm-invalid"):
    log_path.unlink(missing_ok=True)
    env = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MODE=mode)
    client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session"], env, work)
    try:
        sid = client.call("initialize", {"protocol_version": "3.0", "capabilities": {"approvals": True}})["session"]["session_id"]
        client.on_approval = lambda p: "allow"
        s1 = client.call("agent.prompt", {"session_id": sid, "input": "run probe"})
        client.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})
        assert len(client.approvals) == 0, (mode, client.approvals)
        assert not any("PROBE EXECUTED" in json.dumps(ev) for ev in client.events), (mode, client.events)
    finally:
        client.call("shutdown")
        client.p.wait(timeout=10)
PY

# (b) Empty/unmatched PermissionRequest abstains -> TUI modal appears -> approve executes tool, deny blocks execution.
export PARITY_MODE="perm-empty"
rm -f "$PARITY_LOG"
rc=0
python3 - <<'PY' || rc=$?
import os, sys
if os.name == "nt":
    print("SKIPPED[capability=posix.pty] POSIX PTY driver")
    sys.exit(77)
import importlib.util, json, pathlib
sys.path.insert(0, os.environ["MARE_PLUGINS_PTY"])
spec = importlib.util.spec_from_file_location("pty_terminal", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "pty_terminal.py")
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)
terminal.BOOT = 25

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = pathlib.Path(os.environ["PARITY_LOG"])
env = {k: v for k, v in os.environ.items() if k != "TERM"}
env["MARE_NO_TERM_PROBE"] = "1"

@terminal.cleanup.scoped
def test_approve():
    tty = terminal.Tty(os.environ["MARE_BIN"], ["--no-session", "-C", str(work)], False, env)
    try:
        tty.ready()
        tty.submit(b"run probe", until=lambda raw: "Allow once (y)" in terminal.plain(raw))
        modal_text = terminal.plain(tty.out)
        assert "Allow once (y)" in modal_text, modal_text[-2000:]
        os.write(tty.master, b"\r")
        tty.pump(10, until=lambda raw: "PROBE EXECUTED actual" in terminal.plain(raw) and "done" in terminal.plain(raw))
        visible = terminal.plain(tty.out)
        assert "PROBE EXECUTED actual" in visible and "done" in visible, visible[-2000:]
        tty.quit()
        assert tty.p.returncode == 0
    finally:
        if tty.p.poll() is None:
            tty.p.kill()
            tty.p.wait()

@terminal.cleanup.scoped
def test_deny():
    tty = terminal.Tty(os.environ["MARE_BIN"], ["--no-session", "-C", str(work)], False, env)
    try:
        tty.ready()
        tty.submit(b"run probe", until=lambda raw: "Allow once (y)" in terminal.plain(raw))
        modal_text = terminal.plain(tty.out)
        assert "Allow once (y)" in modal_text, modal_text[-2000:]
        os.write(tty.master, b"\x1b")
        tty.pump(10, until=lambda raw: "done" in terminal.plain(raw) or "denied" in terminal.plain(raw) or "Refused" in terminal.plain(raw))
        visible = terminal.plain(tty.out)
        assert "PROBE EXECUTED actual" not in visible, visible[-2000:]
        tty.quit()
        assert tty.p.returncode == 0
    finally:
        if tty.p.poll() is None:
            tty.p.kill()
            tty.p.wait()

test_approve()
events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
assert any(e["event"] == "PermissionRequest" for e in events), events
log_path.unlink(missing_ok=True)
test_deny()
events_deny = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
assert any(e["event"] == "PermissionRequest" for e in events_deny), events_deny
PY
if [[ "$rc" -eq 77 ]]; then
  had_skip=1
elif [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

# (c) PermissionRequest deny + another tool/approval listener returns allow -> DENIED.
mkdir -p "$MARE_HOME/config/plugins"
cat >"$MARE_HOME/config/plugins/other-allow.lua" <<'LUA'
return {
  name = "other-allow",
  inject = { "policy" },
  apply = function(ctx)
    ctx.policy:voter("tool/approval", function()
      return { decision = "allow", source = "policy" }
    end, { prepend = true })
  end,
}
LUA
export PARITY_MODE="perm-deny"
rm -f "$PARITY_LOG"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/perm-deny-other.jsonl" || true
rg -q 'PERM DENIED' "$tmp_root/perm-deny-other.jsonl"
refute_rg 'PROBE EXECUTED' "$tmp_root/perm-deny-other.jsonl"
rm -f "$MARE_HOME/config/plugins/other-allow.lua" "$MARE_HOME/config/plugins/ask-probe.lua"

# (f) A tool/before policy deny overrides a PermissionRequest allow.
cat >"$MARE_HOME/config/plugins/before-deny.lua" <<'LUA'
return {
  name = "before-deny",
  inject = { "policy" },
  apply = function(ctx)
    ctx.policy:voter("tool/before", function()
      return { decision = "deny", reason = "BEFORE POLICY DENIED" }
    end)
  end,
}
LUA
export PARITY_MODE="perm-allow"
rm -f "$PARITY_LOG"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'run probe' >"$tmp_root/before-deny.jsonl" || true
rg -q 'BEFORE POLICY DENIED' "$tmp_root/before-deny.jsonl"
refute_rg 'PROBE EXECUTED' "$tmp_root/before-deny.jsonl"
rm -f "$MARE_HOME/config/plugins/before-deny.lua"

# (e) Hidden-value restoration with a hook allow and no human approval is not allowed.
cat >"$MARE_HOME/config/plugins/u2-probe.lua" <<LUA
return {
  name = "u2-probe",
  inject = { "tools", "commands" },
  apply = function(ctx)
    local keep = mare.projection.register("SECRET_U2_TOKEN_9f3a")
    ctx.tools:register("hidden_probe", {
      description = "u2 probe",
      side_effect = "external",
      sensitive_inputs = { "token" },
      parameters = { type = "object", properties = { token = { type = "string" } }, required = { "token" } },
      execute = function(args)
        return "U2 EXECUTED " .. tostring(args.token)
      end,
    })
    ctx.commands:register("test-u2", {
      description = "run u2 probe",
      run = function()
        local r = ctx.tools:execute({ id = "u2-1", name = "hidden_probe", arguments = { token = keep.reference } }, {})
        mare.fs.write("$host_tmp_root/u2-res.json", mare.json.encode_strict(r))
      end,
    })
  end,
}
LUA
export PARITY_MODE="perm-allow"
rm -f "$PARITY_LOG" "$tmp_root/u2-res.json"
python3 - <<'PY'
import importlib.util, json, os, pathlib
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
env = dict(os.environ)
client = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--no-session"], env, work)
try:
    client.call("initialize", {"protocol_version": "3.0"})
    res = client.call("commands.run", {"line": "/test-u2"})
    assert isinstance(res, dict), res
finally:
    client.call("shutdown")
    client.p.wait(timeout=10)
PY
jq -e '.refused == true and (.is_error == true) and ((.content // "") | contains("U2 EXECUTED") | not)' "$tmp_root/u2-res.json" >/dev/null
jq -s -e '([.[] | select(.event == "PermissionRequest")] | length) == 1' "$PARITY_LOG" >/dev/null
rm -f "$MARE_HOME/config/plugins/u2-probe.lua"

# 11. N6 (matcher-bound trust hash), N7 (enabled=false persistence across restart),
#     shell-quote env expansion, discover layers + trust gate, PreToolUse additionalContext,
#     >64KiB spill-to-file, statusMessage activity, and hooks/audit + session/loaded replay.
rm -rf "$MARE_HOME/state/hooks.json" "$MARE_HOME/state/state.json" "$MARE_HOME/state/spill"
mkdir -p "$tmp_root/work/plug's root/bin" "$tmp_root/work/.mare" "$tmp_root/work/.claude" "$tmp_root/work/.codex"
cat >"$tmp_root/work/plug's root/bin/quoted.py" <<'PY'
import json, os, sys
p = json.load(sys.stdin)
with open(os.environ["PARITY_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"event": p["hook_event_name"], "tag": "quoted", "cwd_arg": sys.argv[1], "slot": sys.argv[2] if len(sys.argv) > 2 else ""}) + "\n")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "additionalContext": "PRE_TOOL_CONTEXT_PARITY"}}))
PY
cat >"$tmp_root/work/spill_start.py" <<'PY'
import json, os, sys
p = json.load(sys.stdin)
with open(os.environ["PARITY_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"event": p["hook_event_name"], "tag": "start"}) + "\n")
print("S" * 70000)
PY
cat >"$tmp_root/parity-section11-script.json" <<'JSON'
[
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"section11 done"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"section11b done"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/parity-section11-script.json"

# N6 + N7 config driven by PARITY_MATCHER
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
local m = mare.env("PARITY_MATCHER") or "hooks_probe"
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  requireTrust = true,
  sources = {
    {
      dialect = "claude-code",
      plugin_root = [=[$host_tmp_root/work/plug's root]=],
      hooks = {
        PreToolUse = {
          { matcher = m, hooks = {
            { command = [[python3 '\${CLAUDE_PLUGIN_ROOT}/bin/quoted.py' "\${CLAUDE_PROJECT_DIR}" "1"]], statusMessage = "Checking quoted hook...", timeout = 5 },
            { command = [[python3 '\${CLAUDE_PLUGIN_ROOT}/bin/quoted.py' "\${CLAUDE_PROJECT_DIR}" "2"]], enabled = false, timeout = 5 },
          } },
        },
      },
    },
  },
} } } }
LUA

python3 - <<'PY'
import importlib.util, json, os, pathlib
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

class TrustClient(rpc.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.selects = []
        self.notifies = []

    def dispatch(self, message):
        m = message.get("method")
        if m == "ui.select" and "id" in message:
            self.selects.append(message.get("params", {}))
            self.send({"id": message["id"], "result": {"index": 0}})
            return None
        if m == "ui.notify":
            self.notifies.append(message.get("params", {}))
            return None
        return super().dispatch(message)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "n6-n7.jsonl"
log_path.unlink(missing_ok=True)
env1 = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MATCHER="hooks_probe")

def prompt_wait(client, sid, text):
    s = client.call("agent.prompt", {"session_id": sid, "input": text})
    return client.call("agent.wait", {"session_id": sid, "turn_id": s["turn_id"]})

# Pass 1: trust handler #1 (remember), verify disabled handler #2 skipped, then /hooks enable 2.
c1 = TrustClient([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env1, work)
try:
    sid1 = c1.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})["session"]["session_id"]
    prompt_wait(c1, sid1, "pass 1")
    assert len(c1.selects) == 1 and c1.selects[0]["title"] == "Trust hook handler?", c1.selects
    assert "Matcher: hooks_probe" in c1.selects[0]["body"], c1.selects[0]
    ev1 = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len(ev1) == 1 and pathlib.Path(ev1[0]["cwd_arg"]).resolve() == work.resolve(), ev1

    # Enable handler #2 (was enabled=false) and trust it; prompt again -> both run.
    enabled = c1.call("commands.run", {"line": "/hooks enable 2"})
    # commands.run returns {result = {status}} when a command returns a table
    assert (enabled.get("result") or enabled).get("status") == "completed", enabled
    prompt_wait(c1, sid1, "pass 1b")
    assert len(c1.selects) == 2, c1.selects
    ev1b = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len(ev1b) == 3, ev1b
finally:
    c1.call("shutdown")
    c1.p.wait(timeout=10)

# Pass 2: brand new process with SAME matcher -> NO trust prompt, and handler #2 STAYS enabled (N7)!
log_path.unlink(missing_ok=True)
c2 = TrustClient([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env1, work)
try:
    sid2 = c2.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})["session"]["session_id"]
    prompt_wait(c2, sid2, "pass 2")
    assert len(c2.selects) == 0, f"expected persisted trust + enabled across restart, got {c2.selects}"
    ev2 = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert len(ev2) == 2, f"expected enabled=false handler to stay enabled after restart, got {ev2}"
finally:
    c2.call("shutdown")
    c2.p.wait(timeout=10)

# Pass 3: brand new process with CHANGED matcher '*' -> MUST re-confirm trust (N6)!
log_path.unlink(missing_ok=True)
env3 = dict(os.environ, PARITY_LOG=str(log_path), PARITY_MATCHER="*")
c3 = TrustClient([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env3, work)
try:
    sid3 = c3.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})["session"]["session_id"]
    prompt_wait(c3, sid3, "pass 3")
    assert len(c3.selects) == 2, f"expected re-confirmation when matcher changed to *, got {c3.selects}"
    assert "Matcher: *" in c3.selects[0]["body"], c3.selects[0]
finally:
    c3.call("shutdown")
    c3.p.wait(timeout=10)
PY

# Discovery layers (.mare, .claude, .codex, packages) + trust gating + PreToolUse additionalContext + SessionStart
# disclosure + audit replay; the >64KiB SessionStart spill is a separate check after this one
real_cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/mare-plugins"
mkdir -p "$real_cache_home"
disc_home="$(mktemp -d "$real_cache_home/parity-disc-home.XXXXXX")"
host_disc_home="$disc_home"
if command -v cygpath >/dev/null 2>&1; then
  host_disc_home="$(cygpath -m "$disc_home")"
fi
mkdir -p "$tmp_root/package/hooks" "$tmp_root/discover-work/.mare" "$tmp_root/discover-work/.claude" "$tmp_root/discover-work/.codex" "$tmp_root/untrusted-work/.mare" "$tmp_root/fake-home" "$disc_home/config" "$disc_home/bin"
cp "$tmp_root/work/plug's root/bin/quoted.py" "$tmp_root/package/hooks/pkg_quoted.py"
cat >"$tmp_root/package/hooks/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 '${CLAUDE_PLUGIN_ROOT}/hooks/pkg_quoted.py' \"${CLAUDE_PROJECT_DIR}\"","statusMessage":"Checking package hook..."}]}]}}
JSON
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm pkg-hooks
export HOME="$tmp_root/fake-home"
export MARE_HOME="$disc_home"
cat >"$disc_home/bin/short_start.py" <<'PY'
import json, os, sys
p = json.load(sys.stdin)
with open(os.environ["PARITY_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"event": p["hook_event_name"], "tag": "start"}) + "\n")
print("SHORT_START_DISCLOSURE")
PY
cat >"$disc_home/bin/log_tag.py" <<'PY'
import json, os, sys
with open(os.environ["PARITY_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"tag": sys.argv[1]}) + "\n")
PY
cat >"$MARE_HOME/config/hooks.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"python3 '$host_disc_home/bin/short_start.py'"}]}]}}
JSON
# the project layers are PreToolUse hooks: discovery does not depend on the event, and PostToolUse
# needs core's tools.capabilities, so PostToolUse layers would gate the whole check.
cat >"$tmp_root/discover-work/.mare/hooks.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 '$host_disc_home/bin/log_tag.py' proj-mare"}]}]}}
JSON
cat >"$tmp_root/discover-work/.claude/settings.json" <<JSON
{"model":"ignored","hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 '$host_disc_home/bin/log_tag.py' proj-claude"}]}]}}
JSON
cat >"$tmp_root/discover-work/.codex/hooks.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 '$host_disc_home/bin/log_tag.py' proj-codex"}]}]}}
JSON
cat >"$tmp_root/untrusted-work/.mare/hooks.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 '$host_disc_home/bin/log_tag.py' UNTRUSTED"}]}]}}
JSON

cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  discover = true,
} } } }
LUA
"$mare_bin" -C "$tmp_root/discover-work" plugin sync
"$mare_bin" -C "$tmp_root/discover-work" trust

# Untrusted project dir skips project .mare hooks
export PARITY_LOG="$tmp_root/untrusted.jsonl"
rm -f "$PARITY_LOG"
"$mare_bin" -C "$tmp_root/untrusted-work" --yolo -p --no-session --json 'untrusted discover check' >"$tmp_root/untrusted-out.jsonl"
rg -q '"start"' "$PARITY_LOG" # the user layer did run
refute_rg '"UNTRUSTED"' "$PARITY_LOG"

# Trusted project dir runs discovered user, package, .mare, .claude, .codex hooks;
# PreToolUse additionalContext & the SessionStart output reach session messages;
# resume replays hooks/audit notifications without re-executing tool hooks!
python3 - <<'PY'
import importlib.util, json, os, pathlib
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

class AuditClient(rpc.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.notifies = []

    def dispatch(self, message):
        if message.get("method") == "ui.notify":
            self.notifies.append(message.get("params", {}))
            return None
        return super().dispatch(message)

work = pathlib.Path(os.environ["PARITY_RPC_WORK"]).parent / "discover-work"
log_path = work / "discover-audit.jsonl"
log_path.unlink(missing_ok=True)
env = dict(os.environ, PARITY_LOG=str(log_path))

c1 = AuditClient([os.environ["MARE_BIN"], "--rpc", "--yolo", "--session-id", "audit-replay-1"], env, work)
try:
    sess_id = c1.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})["session"]["session_id"]
    s1 = c1.call("agent.prompt", {"session_id": sess_id, "input": "run discovered"})
    c1.call("agent.wait", {"session_id": sess_id, "turn_id": s1["turn_id"]})
    rows = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    tags = {r["tag"] for r in rows}
    assert {"start", "quoted", "proj-mare", "proj-claude", "proj-codex"}.issubset(tags), rows
    quoted = [r for r in rows if r["tag"] == "quoted"][0]
    assert pathlib.Path(quoted["cwd_arg"]).resolve() == work.resolve(), quoted

    sess_id = c1.call("status.get")["session"]["session_id"]
    msgs = c1.call("agent.list_messages", {"session_id": sess_id})["data"]
    disclosures = [m for m in msgs if m.get("context_disclosure", {}).get("source") == "hooks"]
    joined = "\n".join(b.get("text", "") for m in disclosures for b in m.get("content", []) if isinstance(b, dict))
    assert "PRE_TOOL_CONTEXT_PARITY" in joined, disclosures
    assert "SHORT_START_DISCLOSURE" in joined, joined
finally:
    c1.call("shutdown")
    c1.p.wait(timeout=10)

# Resume the saved session -> hooks/audit replay notifies UI + populates activity without re-running PreToolUse/PostToolUse.
before_resume_count = len([json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()])
c2 = AuditClient([os.environ["MARE_BIN"], "--rpc", "--yolo"], env, work)
try:
    c2.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})
    c2.call("session.load", {"session_id": sess_id})
    after_resume_rows = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    new_tags = [r["tag"] for r in after_resume_rows[before_resume_count:]]
    assert all(t == "start" for t in new_tags), new_tags
    assert any("Replayed " in n.get("text", "") and "hook audit" in n.get("text", "") for n in c2.notifies), c2.notifies
    act = c2.call("agent.get", {"session_id": sess_id})["activity"]
    hooks_act = (act.get("extra") or {}).get("hooks") or {}
    assert len(hooks_act.get("replayed") or []) >= 4, act
finally:
    c2.call("shutdown")
    c2.p.wait(timeout=10)
PY

# >64KiB SessionStart output: spilled to <state>/spill/hooks-*.log, a preview reaches the session.
cat >"$MARE_HOME/config/hooks.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"python3 '$host_tmp_root/work/spill_start.py'"}]}]}}
JSON
export PARITY_LOG="$tmp_root/spill-start.jsonl"
rm -f "$PARITY_LOG"
python3 - <<'PY'
import importlib.util, os, pathlib
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)
work = pathlib.Path(os.environ["PARITY_RPC_WORK"]).parent / "discover-work"
c = rpc.Client([os.environ["MARE_BIN"], "--rpc", "--yolo", "--no-session"], dict(os.environ), work)
try:
    sid = c.call("initialize", {"protocol_version": "3.0"})["session"]["session_id"]
    s1 = c.call("agent.prompt", {"session_id": sid, "input": "spill the session start"})
    c.call("agent.wait", {"session_id": sid, "turn_id": s1["turn_id"]})
    msgs = c.call("agent.list_messages", {"session_id": sid})["data"]
    joined = "\n".join(b.get("text", "") for m in msgs if m.get("context_disclosure", {}).get("source") == "hooks" for b in m.get("content", []) if isinstance(b, dict))
    assert "[Full hook output (70000 bytes) saved to " in joined, joined[:2000]
    spill_files = list((pathlib.Path(os.environ["MARE_HOME"]) / "state" / "spill").glob("hooks-*.log"))
    assert any(f.read_text(encoding="utf-8") == "S" * 70000 for f in spill_files), spill_files
finally:
    c.call("shutdown")
    c.p.wait(timeout=10)
PY


# 14. Async command hooks (non-blocking execution, Stop/deny ignore, non-waking additionalContext + systemMessage,
#     statusMessage activity, session switch stale drop, and shutdown process reap; ZERO sleep).
cat >"$tmp_root/work/plugin-root/async_hook.py" <<'PY'
import json, os, select, signal, sys

p = json.load(sys.stdin)
ev = p["hook_event_name"]
with open(os.environ["ASYNC_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"event": ev, "pid": os.getpid()}) + "\n")

if ev == "Stop":
    print(json.dumps({
        "continue": False,
        "stopReason": "ASYNC_STOP_SHOULD_IGNORE",
        "decision": "block",
        "reason": "ASYNC_BLOCK_SHOULD_IGNORE",
        "systemMessage": "ASYNC_STOP_SYS",
    }))
    sys.exit(0)

mode = os.environ.get("ASYNC_MODE", "normal")
if os.path.exists(os.environ["ASYNC_STALE_FLAG"]):
    mode = "stale"
elif os.path.exists(os.environ["ASYNC_HANG_FLAG"]):
    mode = "hang"

start_fifo = os.environ["ASYNC_START_FIFO"]
release_fifo = os.environ["ASYNC_RELEASE_FIFO"]

if mode == "hang":
    with open(os.environ["ASYNC_HANG_PID"], "w", encoding="utf-8") as pf:
        pf.write(str(os.getpid()))
    fd_s = os.open(start_fifo, os.O_RDWR)
    os.write(fd_s, b"1")
    os.close(fd_s)
    signal.pause()
    sys.exit(0)

fd_s = os.open(start_fifo, os.O_RDWR)
fd_r = os.open(release_fifo, os.O_RDWR)
os.write(fd_s, b"1")
os.close(fd_s)
ready, _, _ = select.select([fd_r], [], [], 10)
if ready:
    os.read(fd_r, 1)
os.close(fd_r)

if mode == "stale":
    print(json.dumps({
        "systemMessage": "STALE_SYS",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": "STALE_CTX",
        },
    }))
else:
    print(json.dumps({
        "systemMessage": "ASYNC_PRE_SYS",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "IGNORED_ASYNC_DENY",
            "additionalContext": "ASYNC_PRE_CONTEXT",
        },
    }))
PY

cat >"$tmp_root/parity-section14-script.json" <<'JSON'
[
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"async 1 done"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"async 2 done"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"async 3 done"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"async 4 done"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"async 5 done"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/parity-section14-script.json"

cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  sources = {
    {
      dialect = "claude-code",
      plugin_root = "$host_tmp_root/work/plugin-root",
      hooks = {
        PreToolUse = {
          { matcher = "hooks_probe", hooks = {
            {
              command = "python3 '\${CLAUDE_PLUGIN_ROOT}/async_hook.py'",
              async = true,
              timeout = 15,
              statusMessage = "Async hook running...",
            },
          } },
        },
        Stop = {
          { hooks = {
            {
              command = "python3 '\${CLAUDE_PLUGIN_ROOT}/async_hook.py'",
              async = true,
              timeout = 15,
            },
          } },
        },
      },
    },
  },
} } } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
rc=0
python3 - <<'PY' || rc=$?
import os, sys
if not hasattr(os, "mkfifo"):
    print("SKIPPED[capability=posix.fifo] POSIX FIFO driver")
    sys.exit(77)
import importlib.util, json, pathlib, select, subprocess, threading, time
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


class AsyncClient(rpc.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.notifies = []

    def dispatch(self, message):
        if message.get("method") == "ui.notify":
            self.notifies.append(message.get("params", {}))
            return None
        return super().dispatch(message)

    def wait_notify(self, needle, timeout=60):
        # a blocked readline cannot time out by itself: a watchdog stops mare at the deadline,
        # which ends the read, and the wait fails with what did arrive
        watchdog = threading.Timer(timeout, self.p.kill)
        watchdog.start()
        try:
            while not any(needle in n.get("text", "") for n in self.notifies):
                try:
                    self.dispatch(self.read())
                except RuntimeError:
                    raise AssertionError(f"no ui.notify containing {needle!r} within {timeout}s: {self.notifies}")
        finally:
            watchdog.cancel()

    def wait_stop_notify(self, needle):
        self.wait_notify(needle)


work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
log_path = work / "async-hook.jsonl"
log_path.unlink(missing_ok=True)
start_fifo = work / "async-start.fifo"
release_fifo = work / "async-release.fifo"
stale_flag = work / "async-stale.flag"
hang_flag = work / "async-hang.flag"
hang_pid_file = work / "async-hang.pid"
for p in (start_fifo, release_fifo, stale_flag, hang_flag, hang_pid_file):
    p.unlink(missing_ok=True)
os.mkfifo(start_fifo)
os.mkfifo(release_fifo)
start_fd = os.open(start_fifo, os.O_RDWR)
release_fd = os.open(release_fifo, os.O_RDWR)

env = dict(
    os.environ,
    ASYNC_LOG=str(log_path),
    ASYNC_START_FIFO=str(start_fifo),
    ASYNC_RELEASE_FIFO=str(release_fifo),
    ASYNC_STALE_FLAG=str(stale_flag),
    ASYNC_HANG_FLAG=str(hang_flag),
    ASYNC_HANG_PID=str(hang_pid_file),
)
def prompt_wait(client, sid, text):
    s = client.call("agent.prompt", {"session_id": sid, "input": text})
    return client.call("agent.wait", {"session_id": sid, "turn_id": s["turn_id"]})


def live_async_hook_pids(script_path):
    pids = []
    if pathlib.Path("/proc").is_dir():
        needle = script_path.encode()
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                cmdline = (entry / "cmdline").read_bytes()
            except OSError:
                continue
            if b"python" in cmdline and needle in cmdline:
                pids.append(int(entry.name))
        return pids
    if os.name == "nt":
        out = subprocess.check_output(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                "Get-CimInstance Win32_Process | ForEach-Object { \"$($_.ProcessId) $($_.CommandLine)\" }",
            ],
            text=True,
            encoding="utf-8",
        )
    else:
        out = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, encoding="utf-8")
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and "python" in parts[1].lower() and script_path in parts[1]:
            pids.append(int(parts[0]))
    return pids


hang_script = str(work / "plugin-root/async_hook.py")
client = AsyncClient([os.environ["MARE_BIN"], "--rpc", "--yolo"], env, work)
try:
    sid = client.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})["session"]["session_id"]

    # (a) Non-blocking PreToolUse + async Stop continue:false/block ignored while PreToolUse is still paused on FIFO.
    prompt_wait(client, sid, "async hook run 1")
    assert any(
        ev.get("type") == "item/completed"
        and (ev.get("data") or {}).get("item", {}).get("type") == "tool_call"
        and "PROBE EXECUTED actual" in json.dumps(ev)
        for ev in client.events
    ), client.events
    ready, _, _ = select.select([start_fd], [], [], 10)
    assert ready, "timed out waiting for async PreToolUse process to start"
    os.read(start_fd, 1)

    act = client.call("agent.get", {"session_id": sid})["activity"]
    hooks_act = (act.get("extra") or {}).get("hooks") or {}
    active = hooks_act.get("active") or []
    assert any(a.get("async") is True and a.get("status_message") == "Async hook running..." for a in active), act

    # Release async PreToolUse; verify completion notify + non-waking context delivered on next prompt.
    os.write(release_fd, b"1")
    client.wait_notify("ASYNC_PRE_SYS")
    client.wait_stop_notify("ASYNC_STOP_SYS")
    assert client.call("agent.get", {"session_id": sid})["busy"] is False, "async context notify must not wake idle agent"

    # (b) Subsequent prompt receives ASYNC_PRE_CONTEXT without waking earlier.
    client.notifies.clear()
    prompt_wait(client, sid, "async hook followup")
    ready, _, _ = select.select([start_fd], [], [], 10)
    assert ready
    os.read(start_fd, 1)
    os.write(release_fd, b"1")
    client.wait_notify("ASYNC_PRE_SYS")
    client.wait_stop_notify("ASYNC_STOP_SYS")
    msgs = client.call("agent.list_messages", {"session_id": sid})["data"]
    joined = json.dumps(msgs)
    assert "ASYNC_PRE_CONTEXT" in joined, msgs
    assert "IGNORED_ASYNC_DENY" not in joined and "ASYNC_STOP_SHOULD_IGNORE" not in joined, msgs

    # (c) Session switch cancels & drops stale async hook results.
    stale_flag.write_text("1", encoding="utf-8")
    prompt_wait(client, sid, "async stale trigger")
    ready, _, _ = select.select([start_fd], [], [], 10)
    assert ready
    os.read(start_fd, 1)
    old_sid = sid
    sid = client.call("session.create", {})["session_id"]
    client.call("session.close", {"session_id": old_sid})
    stale_flag.unlink(missing_ok=True)
    client.notifies.clear()
    prompt_wait(client, sid, "new session after switch")
    ready, _, _ = select.select([start_fd], [], [], 10)
    assert ready
    os.read(start_fd, 1)
    os.write(release_fd, b"1")
    client.wait_notify("ASYNC_PRE_SYS")
    client.wait_stop_notify("ASYNC_STOP_SYS")
    assert not any("STALE_SYS" in n.get("text", "") for n in client.notifies), client.notifies
    new_msgs = json.dumps(client.call("agent.list_messages", {"session_id": sid})["data"])
    assert "STALE_CTX" not in new_msgs, new_msgs

    # (d) Clean shutdown cancels & reaps hanging async child process.
    hang_flag.write_text("1", encoding="utf-8")
    prompt_wait(client, sid, "async hang trigger")
    ready, _, _ = select.select([start_fd], [], [], 10)
    assert ready
    os.read(start_fd, 1)
    assert hang_pid_file.read_text(encoding="utf-8").strip().isdigit()
    assert live_async_hook_pids(hang_script), "hanging async hook process not observed on host"
finally:
    os.close(start_fd)
    os.close(release_fd)
    for p in (start_fifo, release_fifo, stale_flag, hang_flag):
        p.unlink(missing_ok=True)
    client.call("shutdown")
    assert client.p.wait(timeout=10) == 0

remaining_pids = live_async_hook_pids(hang_script)
assert not remaining_pids, f"async hook child process(es) {remaining_pids} survived shutdown"
hang_pid_file.unlink(missing_ok=True)
PY
if [[ "$rc" -eq 77 ]]; then
  had_skip=1
elif [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

# 15. Plugin package content hash, execution-time re-verification, and fail-closed fingerprint errors.
mkdir -p "$tmp_root/work/plugin-fp"
cat >"$tmp_root/work/plugin-fp/helper.py" <<'PY'
VERSION = "v1"
PY
cat >"$tmp_root/work/plugin-fp/run.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import helper
with open(os.environ["PARITY_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"version": helper.VERSION}) + "\n")
print("{}")
PY
cat >"$tmp_root/work/plugin-fp/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"hooks_probe","hooks":[{"type":"command","command":"python3 '${CLAUDE_PLUGIN_ROOT}/run.py'","timeout":5}]}]}}
JSON
cat >"$tmp_root/parity-section15-script.json" <<'JSON'
[
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"fp 1"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"fp 2"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"fp 3"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"fp 4"},
  {"tool_calls":[{"name":"hooks_probe","arguments":{"value":"actual"}}]},
  {"text":"fp 5"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/parity-section15-script.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/hooks", url = "file://$tmp_root/package", opts = { hooks = {
  requireTrust = true,
  sources = {
    {
      dialect = "claude-code",
      plugin_root = "$host_tmp_root/work/plugin-fp",
      path = "$host_tmp_root/work/plugin-fp/hooks.json",
    },
  },
} } } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
python3 - <<'PY'
import importlib.util, json, os, pathlib
spec = importlib.util.spec_from_file_location("rpc_client", pathlib.Path(os.environ["MARE_PLUGINS_PTY"]) / "rpc_client.py")
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


class FpClient(rpc.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.selects = []

    def dispatch(self, message):
        if message.get("method") == "ui.select" and "id" in message:
            self.selects.append(message.get("params", {}))
            self.send({"id": message["id"], "result": {"index": 0}})
            return None
        return super().dispatch(message)


work = pathlib.Path(os.environ["PARITY_RPC_WORK"])
pkg_fp = work / "plugin-fp"
helper_py = pkg_fp / "helper.py"
log_path = work / "fp-trust.jsonl"
log_path.unlink(missing_ok=True)
env = dict(os.environ, PARITY_LOG=str(log_path))

def prompt_wait(client, sid, text):
    s = client.call("agent.prompt", {"session_id": sid, "input": text})
    return client.call("agent.wait", {"session_id": sid, "turn_id": s["turn_id"]})

c = FpClient([os.environ["MARE_BIN"], "--rpc", "--no-session", "--yolo"], env, work)
try:
    sid = c.call("initialize", {"protocol_version": "3.0", "capabilities": {"ui": True}})["session"]["session_id"]

    # Initial approval + cached execution while bundle unchanged.
    prompt_wait(c, sid, "fp 1")
    assert len(c.selects) == 1, c.selects
    prompt_wait(c, sid, "fp 2")
    assert len(c.selects) == 1, c.selects
    rows = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert [r["version"] for r in rows] == ["v1", "v1"], rows

    # Modify helper.py in place without touching hooks.json or restarting -> must re-confirm with new hash!
    helper_py.write_text('VERSION = "v2"\n', encoding="utf-8")
    prompt_wait(c, sid, "fp 3")
    assert len(c.selects) == 2, f"expected re-approval after script tamper, got {c.selects}"
    sha1 = [line for line in c.selects[0]["body"] if line.startswith("SHA-256: ")][0]
    sha2 = [line for line in c.selects[1]["body"] if line.startswith("SHA-256: ")][0]
    assert sha1 != sha2, (sha1, sha2)
    rows = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert [r["version"] for r in rows] == ["v1", "v1", "v2"], rows

    # Unreadable file inside plugin root -> fingerprint verification fails closed without prompting ui.select!
    if os.name != "nt":
        os.chmod(helper_py, 0)
        try:
            c.events.clear()
            prompt_wait(c, sid, "fp 4")
            assert len(c.selects) == 2, f"fingerprint error must fail closed without ui.select, got {c.selects}"
            rows_during_fail = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
            assert len(rows_during_fail) == 3, rows_during_fail
            assert any(
                ev.get("type") == "item/completed"
                and "plugin content verification failed" in json.dumps(ev)
                for ev in c.events
            ), c.events
        finally:
            os.chmod(helper_py, 0o644)

    # Restored file matching v2 approval runs cleanly without prompting again.
    prompt_wait(c, sid, "fp 5")
    assert len(c.selects) == 2, c.selects
    rows_final = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
    assert [r["version"] for r in rows_final] == ["v1", "v1", "v2", "v2"], rows_final
finally:
    os.chmod(helper_py, 0o644)
    c.call("shutdown")
    assert c.p.wait(timeout=10) == 0
PY

if [[ "$had_skip" -eq 1 ]]; then
  exit 77
fi
printf 'hooks parity: SessionEnd, PermissionRequest, PreCompact/PostCompact, trust, /hooks, legacy notify, dedup, quoting, discover, PreToolUse context, spill, statusMessage, audit replay, async hooks and plugin content verification passed\n'
