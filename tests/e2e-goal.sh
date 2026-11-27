#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-goal-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp "$repo_root/LICENSE" "$tmp_root/package/"
cp -R "$repo_root/plugins/goal" "$tmp_root/package/plugins/"
cp -R "$repo_root/plugins/plan-mode" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/goal-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" GOAL_CAPTURE="$tmp_root/requests.jsonl"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
local threshold=tonumber(mare.env("GOAL_TEST_THRESHOLD"))
if threshold then mare.plugin("goal",{blocked_after_consecutive_rounds=threshold}) end
mare.plugins.add { { "test/goal", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"probe complete"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
GOAL_PROBE=contracts GOAL_REPORT="$tmp_root/contracts.json" "$mare_bin" -C "$tmp_root/work" --yolo -p --session-id goal-e2e 'probe goal contracts' >"$tmp_root/run.txt"
jq -e '.ok and .detail == "passed"' "$tmp_root/contracts.json" >/dev/null || { cat "$tmp_root/contracts.json"; exit 1; }
GOAL_PROBE=resume GOAL_REPORT="$tmp_root/resume.json" "$mare_bin" -C "$tmp_root/work" --yolo -p --resume goal-e2e 'check restored goal' >"$tmp_root/resume.txt"
jq -e '.ok' "$tmp_root/resume.json" >/dev/null || { cat "$tmp_root/resume.json"; exit 1; }
GOAL_PROBE=readonly GOAL_REPORT="$tmp_root/ephemeral.json" "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session 'refuse ephemeral goal' >"$tmp_root/ephemeral.txt"
jq -e '.ok' "$tmp_root/ephemeral.json" >/dev/null
# Real faux tool turns use the policy pipeline and confirm that same-run steps do not
# satisfy the three independent-turn blocked threshold. Complete then replaces safely.
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"Explicitly requested test goal","token_budget":10000}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"blocked","blocked_reason":"same external blocker"}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"complete"}}]},
 {"text":"goal achieved"}
]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id goal-tool-e2e 'Explicitly create the supplied test goal, complete it after the fixture is satisfied' >"$tmp_root/tools.jsonl"
jq -s -e 'tostring | contains("3 consecutive automatic goal rounds") and contains("complete") and contains("completion_budget_report")' "$tmp_root/tools.jsonl" >/dev/null
printf 'mare-plugins: goal file:// contracts, journal restore, budgets and faux tool pipeline passed\n'

run_rpc_to_idle() {
  local sid="$1"
  local prompt="$2"
  local out_jsonl="$3"
  python3 - "$mare_bin" "$tmp_root/work" "$sid" "$prompt" "$out_jsonl" <<'PY'
import json, queue, subprocess, sys, threading, time
from pathlib import Path

bin_path, work, sid, prompt, out_path = sys.argv[1:]
proc = subprocess.Popen(
    [bin_path, "-C", work, "--yolo", "--rpc", "--session-id", sid],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    encoding="utf-8",
)
incoming = queue.Queue()
def reader():
    for line in proc.stdout:
        incoming.put(json.loads(line))
    incoming.put(None)
threading.Thread(target=reader, daemon=True).start()
serial = 0
events = []
last_completed = {}
started_order = []
started_seen = set()
completed_ids = set()

def record_event(ev):
    events.append(ev)
    kind = ev.get("type")
    data = ev.get("data") or {}
    if kind == "turn/started":
        tid = data.get("turn_id")
        if tid and tid not in started_seen:
            started_seen.add(tid)
            started_order.append(tid)
    elif kind == "turn/completed":
        last_completed.clear()
        last_completed.update(data)
        tid = data.get("turn_id")
        if tid:
            completed_ids.add(tid)

def call(method, params=None):
    global serial
    serial += 1
    wanted = serial
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": wanted, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    deadline = time.monotonic() + 30
    while True:
        rem = deadline - time.monotonic()
        if rem <= 0:
            raise TimeoutError(f"RPC timeout on {method}")
        msg = incoming.get(timeout=rem)
        if msg is None:
            raise RuntimeError("RPC closed unexpectedly: " + proc.stderr.read())
        if msg.get("method") == "event":
            record_event(msg["params"])
        if msg.get("id") == wanted:
            assert "error" not in msg, msg
            return msg.get("result")

try:
    init = call("initialize", {"protocol_version": "3.0"})
    session_id = init["session"]["session_id"]
    call("events.subscribe", {"session_id": session_id, "include": ["turn/*", "item/*", "step/*", "agent/*", "status/*"]})
    started = call("agent.prompt", {"session_id": session_id, "input": prompt})
    first_tid = started.get("turn_id")
    if first_tid and first_tid not in started_seen:
        started_seen.add(first_tid)
        started_order.append(first_tid)
    waited_ids = set()

    def goal_settled(state):
        if state.get("busy"):
            return False
        if last_completed.get("status") == "failed":
            return True
        goal = ((state.get("activity") or {}).get("extra") or {}).get("goal")
        if not isinstance(goal, dict):
            return True
        return goal.get("status") != "active" or goal.get("activation") != "armed"

    deadline = time.monotonic() + 30
    while True:
        next_tid = next((tid for tid in started_order if tid not in waited_ids), None)
        if next_tid is None:
            state = call("agent.get", {"session_id": session_id})
            active_tid = state.get("turn_id") if state.get("busy") else None
            if active_tid and active_tid not in started_seen:
                started_seen.add(active_tid)
                started_order.append(active_tid)
            next_tid = next((tid for tid in started_order if tid not in waited_ids), None)
            if next_tid is None:
                if completed_ids and goal_settled(state):
                    break
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"agent never became idle; last events={events[-5:]}")
                try:
                    msg = incoming.get(timeout=min(0.05, rem))
                except queue.Empty:
                    continue
                if msg is None:
                    raise RuntimeError("RPC closed unexpectedly: " + proc.stderr.read())
                if msg.get("method") == "event":
                    record_event(msg["params"])
                continue
        call("agent.wait", {"session_id": session_id, "turn_id": next_tid})
        waited_ids.add(next_tid)
        while next_tid not in completed_ids:
            rem = deadline - time.monotonic()
            if rem <= 0:
                raise TimeoutError(f"timed out waiting for turn/completed({next_tid}); last events={events[-5:]}")
            msg = incoming.get(timeout=rem)
            if msg is None:
                raise RuntimeError("RPC closed before turn/completed arrived: " + proc.stderr.read())
            if msg.get("method") == "event":
                record_event(msg["params"])
    call("shutdown")
    proc.wait(timeout=10)
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()

rows = [{"type": e.get("type"), "data": e.get("data")} for e in events]
rows.append({"type": "settled", "data": {"text": last_completed.get("text"), "error": last_completed.get("error")}})
Path(out_path).write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
if last_completed.get("status") == "failed":
    sys.exit(1)
PY
}

cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"Explicitly requested blocked audit fixture"}}]},
 {"text":"same external blocker first observation"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"blocked","blocked_reason":"same external blocker"}}]},
 {"text":"same external blocker second observation"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"blocked","blocked_reason":"same external blocker"}}]},
 {"text":"same external blocker third observation"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"blocked","blocked_reason":"same external blocker"}}]},
 {"text":"goal blocked after three turns"}
]
JSON
run_rpc_to_idle goal-idle-e2e 'Explicitly create a goal for the blocked audit fixture; no independent work is available' "$tmp_root/idle.jsonl"
jq -s -e '[.[] | select(.type == "turn/started")] | length == 4' "$tmp_root/idle.jsonl" >/dev/null
jq -s -e 'tostring | contains("goal blocked after three turns")' "$tmp_root/idle.jsonl" >/dev/null
printf 'mare-plugins: goal independent idle continuation and three-turn blocked audit passed\n'
# An observed budget exhaustion halts this run before an additional model tool
# can act; it is a resource stop, never fabricated goal completion.
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"budget halt fixture","token_budget":1}}]},
 {"tool_calls":[{"name":"write","arguments":{"path":"budget-leak","content":"must not be written"}}]},
 {"text":"Goal budget exhausted; objective remains unfinished."}
]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id goal-budget-e2e 'Explicitly create this goal with the requested one token budget' >"$tmp_root/budget.jsonl"
[[ ! -e "$tmp_root/work/budget-leak" ]]
jq -s -e 'last.data.text=="Goal budget exhausted; objective remains unfinished."' "$tmp_root/budget.jsonl" >/dev/null
printf 'mare-plugins: goal observed budget exhaustion stops further tool effects\n'
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"paused"}}]},
 {"text":"goal paused at the explicit fixture user's request"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"paused"}}]},
 {"text":"resumed goal paused at the explicit fixture user's request"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"paused"}}]},
 {"text":"replacement goal paused at the explicit fixture user's request"}
]
JSON
python3 "$repo_root/tests/goal-ui.py" "$mare_bin" "$tmp_root/work"
# A full system replacement is respected; automatic goal turns remain self-contained.
cat >>"$MARE_HOME/config/init.lua" <<'LUA'
mare.plugin("context", {system="Custom replacement system"})
LUA
: >"$GOAL_CAPTURE"
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"system replacement fixture"}}]},
 {"text":"first goal turn"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"complete"}}]},
 {"text":"complete"}
]
JSON
run_rpc_to_idle goal-system-e2e 'Explicitly create the system replacement fixture goal' "$tmp_root/system.jsonl"
jq -s -e 'all(.[]; .system == "Custom replacement system") and any(.[]; .messages | tostring | contains("Derive all requirements"))' "$GOAL_CAPTURE" >/dev/null
printf 'mare-plugins: goal respects full system replacement and carries its continuation audit\n'
# Final quota errors retain a resource-limited goal; ordinary errors retain an
# unfinished goal and never silently rearm it after a clean session restart.
for case in limited error; do
  if [[ "$case" == limited ]]; then kind=usage_limit; else kind=fatal; fi
  cat >"$tmp_root/script.json" <<JSON
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"$case recovery fixture"}}]},
 {"error":"$case provider failure","kind":"$kind"}
]
JSON
  if run_rpc_to_idle "goal-$case-e2e" 'Explicitly create this recovery fixture goal' "$tmp_root/$case-run.jsonl"; then exit 1; fi
  printf '[{"text":"recovered state inspected"}]' >"$tmp_root/script.json"
  GOAL_PROBE="$case" GOAL_REPORT="$tmp_root/$case-report.json" "$mare_bin" -C "$tmp_root/work" --yolo -p --resume "goal-$case-e2e" 'inspect the saved stopped goal' >"$tmp_root/$case-resume.txt"
  jq -e '.ok' "$tmp_root/$case-report.json" >/dev/null
 done
printf 'mare-plugins: goal quota and ordinary error states survive restart without automatic retry\n'
# A completed automatic round cannot perform another tool in the same assistant
# batch or in a later model step, while its final assistant reply still arrives.
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"terminal tool fence fixture"}}]},
 {"text":"initial user round finished"},
 {"tool_calls":[
   {"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"complete"}},
   {"name":"write","arguments":{"path":"after-complete-batch","content":"must not run"}}
 ]},
 {"tool_calls":[{"name":"write","arguments":{"path":"after-complete-step","content":"must not run"}}]},
 {"text":"terminal final reply preserved"}
]
JSON
run_rpc_to_idle goal-close-e2e 'Explicitly create the terminal tool fence fixture goal' "$tmp_root/close.jsonl"
[[ ! -e "$tmp_root/work/after-complete-batch" && ! -e "$tmp_root/work/after-complete-step" ]]
jq -s -e 'last.data.text == "terminal final reply preserved"' "$tmp_root/close.jsonl" >/dev/null
# Two admitted automatic rounds exhaust the configured cap; the initial human
# round never consumes it. Raising the cap is required before resume.
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"round cap fixture","max_goal_rounds":2}}]},
 {"text":"human round"},{"text":"automatic one"},{"text":"automatic two"}
]
JSON
run_rpc_to_idle goal-cap-e2e 'Explicitly create a goal with a two automatic round cap' "$tmp_root/cap.jsonl"
jq -s -e '[.[]|select(.type=="turn/started")]|length==3' "$tmp_root/cap.jsonl" >/dev/null
printf '[{"text":"inspect capped goal"}]' >"$tmp_root/script.json"
GOAL_PROBE=round-limit GOAL_REPORT="$tmp_root/cap-report.json" "$mare_bin" -C "$tmp_root/work" --yolo -p --resume goal-cap-e2e 'inspect round cap and explicitly raise it before resume' >"$tmp_root/cap-resume.txt"
jq -e '.ok' "$tmp_root/cap-report.json" >/dev/null
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"threshold fixture"}}]},
 {"text":"human round"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"blocked","blocked_reason":"external threshold fixture blocker"}}]},
 {"text":"one automatic observation"},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"blocked","blocked_reason":"external threshold fixture blocker"}}]},
 {"text":"configured threshold reached"}
]
JSON
GOAL_TEST_THRESHOLD=2 run_rpc_to_idle goal-threshold-e2e 'Explicitly create the configured threshold goal' "$tmp_root/threshold.jsonl"
jq -s -e '[.[]|select(.type=="turn/started")]|length==3' "$tmp_root/threshold.jsonl" >/dev/null
jq -s -e 'tostring|contains("model-reported") and contains("external threshold fixture blocker")' "$tmp_root/threshold.jsonl" >/dev/null
printf 'mare-plugins: goal terminal tool fences, safe round cap and configured automatic blocker threshold passed\n'
cancel_rc=0
python3 "$repo_root/tests/goal-cancellation.py" "$mare_bin" "$tmp_root/work" "$tmp_root" || cancel_rc=$?
if [[ $cancel_rc -ne 0 && $cancel_rc -ne 77 ]]; then
  exit "$cancel_rc"
fi
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"empty response fixture"}}]},
 {"text":"human round"},{"text":""},{"text":""},{"text":""}
]
JSON
run_rpc_to_idle goal-empty-e2e 'Explicitly create the empty response fixture goal' "$tmp_root/empty.jsonl"
jq -s -e '[.[]|select(.type=="turn/started")]|length==4' "$tmp_root/empty.jsonl" >/dev/null
printf '[{"text":"inspect empty response state"}]' >"$tmp_root/script.json"
GOAL_PROBE=empty GOAL_REPORT="$tmp_root/empty-report.json" "$mare_bin" -C "$tmp_root/work" --yolo -p --resume goal-empty-e2e 'inspect the saved automatic empty-response stop' >"$tmp_root/empty-resume.txt"
jq -e '.ok' "$tmp_root/empty-report.json" >/dev/null
printf 'mare-plugins: goal stops three consecutive empty automatic responses with empty-response blocker\n'
# The explicit 06:05 final-reply-only rule also applies when the model completes
# a newly created goal in the original user-triggered run, not just auto rounds.
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[
   {"name":"create_goal","arguments":{"objective":"original run terminal fence"}},
   {"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"complete"}},
   {"name":"write","arguments":{"path":"after-human-complete","content":"must not run"}}
 ]},
 {"text":"original run final reply preserved"}
]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id goal-human-close-e2e 'Explicitly create and complete this fixture goal, then only report the result' >"$tmp_root/human-close.jsonl"
[[ ! -e "$tmp_root/work/after-human-complete" ]]
jq -s -e 'last.data.text=="original run final reply preserved"' "$tmp_root/human-close.jsonl" >/dev/null
printf 'mare-plugins: original user-triggered goal completion also forbids later tool effects\n'
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"exact model reference fixture"}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"wrong-goal","revision":1,"status":"complete"}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":0,"status":"complete"}}]},
 {"tool_calls":[{"name":"get_goal","arguments":{}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"complete"}}]},
 {"text":"stale model updates rejected; fresh reference completed"}
]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id goal-model-ref-e2e 'Explicitly create this goal and use the exact model reference' >"$tmp_root/model-ref.jsonl"
jq -s -e '[.[]|select(.type=="item/completed" and .data.item.type=="tool_call" and .data.item.name=="update_goal" and (.data.item.message.is_error==true or .data.item.result.is_error==true))]|length==2' "$tmp_root/model-ref.jsonl" >/dev/null
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"ephemeral model request must fail"}}]},
 {"tool_calls":[{"name":"get_goal","arguments":{}}]},
 {"text":"ephemeral goal was not created"}
]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'Explicitly attempt a goal in this unsaved session and report the refusal' >"$tmp_root/ephemeral-model.jsonl"
jq -s -e 'any(.[];.type=="item/completed" and .data.item.type=="tool_call" and .data.item.name=="create_goal" and (.data.item.message.is_error==true or .data.item.result.is_error==true)) and any(.[];.type=="item/completed" and .data.item.type=="tool_call" and .data.item.name=="get_goal" and (.data.item.message.details.goal // .data.item.result.details.goal)==null)' "$tmp_root/ephemeral-model.jsonl" >/dev/null
printf 'mare-plugins: actual model wrong/stale refs and ephemeral mutations are refused\n'
# Budget-limited is not fabricated completion, but an actually achieved objective
# can still be marked complete. A requested pause must retain the limited status.
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"verify this persisted goal checkpoint using get_goal","token_budget":1}}]},
 {"tool_calls":[{"name":"get_goal","arguments":{}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"paused"}}]},
 {"tool_calls":[{"name":"update_goal","arguments":{"goal_id":"__goal__","revision":1,"status":"complete"}}]},
 {"text":"The persisted checkpoint was verified; budget limitation took precedence over pause, and the actual objective is now complete."}
]
JSON
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id goal-budget-bookkeeping-e2e 'Explicitly create this one-token checkpoint goal, inspect it, request pause, then mark complete only if the checkpoint was actually verified' >"$tmp_root/budget-bookkeeping.jsonl"
jq -s -e '[.[]|select(.type=="item/completed" and .data.item.type=="tool_call" and .data.item.name=="update_goal")|(.data.item.message.details.goal.status // .data.item.result.details.goal.status)] == ["budget_limited","complete"]' "$tmp_root/budget-bookkeeping.jsonl" >/dev/null
printf 'mare-plugins: budget wrap-up preserves final reporting, pause precedence and genuine achievement\n'
cat >"$tmp_root/script.json" <<'JSON'
[
 {"tool_calls":[{"name":"create_goal","arguments":{"objective":"budget bookkeeping loop fixture","token_budget":1}}]},
 {"tool_calls":[{"name":"get_goal","arguments":{}}]},
 {"tool_calls":[{"name":"get_goal","arguments":{}}]},
 {"text":"this repeated bookkeeping response must never be consumed"}
]
JSON
if "$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id goal-budget-loop-e2e 'Explicitly create this one-token budget goal and stop if status-only bookkeeping makes no progress' >"$tmp_root/budget-loop.jsonl"; then exit 1; fi
jq -s -e 'any(.[];.type=="settled" and (.data.error.message|contains("duplicate budget bookkeeping"))) and (tostring|contains("this repeated bookkeeping response must never be consumed")|not)' "$tmp_root/budget-loop.jsonl" >/dev/null
printf 'mare-plugins: budget reporting cannot spin on identical bookkeeping without state progress\n'
[[ "$cancel_rc" -eq 0 ]] || exit 77
