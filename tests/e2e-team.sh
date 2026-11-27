#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then
  mare_bin="$(command -v "$mare_bin")"
fi
[[ -x "$mare_bin" ]] || {
  printf 'Set MARE_BIN to an existing mare executable\n' >&2
  exit 1
}

git_clean() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-team-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/home/state" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/team" "$tmp_root/package/plugins/"
cp -R "$repo_root/plugins/workflow" "$tmp_root/package/plugins/"
git_clean -C "$tmp_root/package" init -q -b main
git_clean -C "$tmp_root/package" add -A
git_clean -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture

export MARE_HOME="$tmp_root/home"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/team", url = "file://$tmp_root/package" } }
LUA
cat >"$MARE_HOME/state/state.json" <<'JSON'
{"version":1,"workflow_enabled":true}
JSON

"$mare_bin" -C "$tmp_root/work" plugin sync

# 1. Parent creates T-1 (high) and blocked T-2 in session team-e2e
cat >"$tmp_root/faux-create.json" <<'JSON'
[
  {"tool_calls":[{"name":"team_create","arguments":{"title":"First task","priority":"high"}}]},
  {"tool_calls":[{"name":"team_create","arguments":{"title":"Second task","blocked_by":["T-1"]}}]},
  {"text":"created tasks"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-create.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id team-e2e 'create initial tasks' >"$tmp_root/create.jsonl"
grep -q "created tasks" "$tmp_root/create.jsonl"

# 2. Resume in parent, spawn a real child VM via workflow; child claims & completes T-1 on the shared locked board
cat >"$tmp_root/faux-child.json" <<'JSON'
[
  {"tool_calls":[{"name":"workflow","arguments":{"meta":{"name":"team-worker","description":"Child claims T-1"},"script":"return { worker = agent('claim and complete T-1', { label = 'worker-1' }) }"}}]},
  {"tool_calls":[{"name":"team_claim","arguments":{"id":"T-1","owner":"worker-child"}}]},
  {"tool_calls":[{"name":"team_complete","arguments":{"id":"T-1","owner":"worker-child","result":"child ok"}}]},
  {"tool_calls":[{"name":"team_list","arguments":{}}]},
  {"text":"child completed T-1"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-child.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --resume team-e2e 'run child worker' >"$tmp_root/team.jsonl"
grep -q "child completed T-1" "$tmp_root/team.jsonl"

# 3. Resume session and verify persisted board state + readiness via team_list
cat >"$tmp_root/faux-resume.json" <<'JSON'
[
  {"tool_calls":[{"name":"team_list","arguments":{}}]},
  {"text":"team resumed ok"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-resume.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --resume team-e2e 'check board' >"$tmp_root/resume.jsonl"

python3 - "$tmp_root/team.jsonl" "$tmp_root/resume.jsonl" "$MARE_HOME/state/sessions" <<'PY'
import glob, json, pathlib, sys

team_jsonl, resume_jsonl, sessions_dir = sys.argv[1], sys.argv[2], sys.argv[3]

# Verify child transcript actually ran team_claim + team_complete (not just parent!)
team_events = [json.loads(line) for line in open(team_jsonl, encoding="utf-8") if line.strip()]
wf_results = [
    e["data"]["item"]
    for e in team_events
    if e.get("type") == "item/completed"
    and isinstance(e.get("data"), dict)
    and isinstance(e["data"].get("item"), dict)
    and e["data"]["item"].get("name") == "workflow"
]
assert len(wf_results) == 1, f"expected 1 workflow call, got {len(wf_results)}"
assert wf_results[0]["message"]["details"]["result"]["worker"] == "child completed T-1", wf_results[0]

child_files = [
    p
    for p in glob.glob(f"{sessions_dir}/**/agents/wf-*/*.jsonl", recursive=True)
    if not any(part.endswith(".snapshots") for part in pathlib.Path(p).parts)
]
assert len(child_files) == 1, f"expected 1 workflow child transcript, got {child_files}"

def iter_dicts(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from iter_dicts(v)
    elif isinstance(node, list):
        for item in node:
            yield from iter_dicts(item)

child_claim_ok = False
child_complete_ok = False
for p in child_files:
    for line in open(p, encoding="utf-8"):
        if not line.strip():
            continue
        rec = json.loads(line)
        for d in iter_dicts(rec):
            if d.get("type") == "tool_result" or d.get("role") == "tool_result" or "is_error" in d:
                if d.get("is_error") is True:
                    continue
                blob = json.dumps(d)
                if "worker-child" in blob and "T-1" in blob:
                    if "in_progress" in blob:
                        child_claim_ok = True
                    if "completed" in blob:
                        child_complete_ok = True
assert child_claim_ok and child_complete_ok, (
    f"expected child transcript {child_files} to execute team_claim and team_complete, got claim={child_claim_ok}, complete={child_complete_ok}"
)

# Parent turn 2 team_claim must see T-1 already completed by child (proving child mutated before parent resumed)
parent_claims = [
    e["data"]["item"]
    for e in team_events
    if e.get("type") == "item/completed"
    and isinstance(e.get("data"), dict)
    and isinstance(e["data"].get("item"), dict)
    and e["data"]["item"].get("name") == "team_claim"
]
assert len(parent_claims) == 1 and parent_claims[0]["result_status"] == "error", parent_claims

for path in (team_jsonl, resume_jsonl):
    events = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    lists = [
        e["data"]["item"]
        for e in events
        if e.get("type") == "item/completed"
        and isinstance(e.get("data"), dict)
        and isinstance(e["data"].get("item"), dict)
        and e["data"]["item"].get("name") == "team_list"
    ]
    assert len(lists) >= 1, f"expected team_list result in {path}"
    res = lists[-1]
    assert res["result_status"] == "success", res
    tasks = {t["id"]: t for t in res["message"]["details"]["tasks"]}
    assert tasks["T-1"]["status"] == "completed" and tasks["T-1"]["owner"] == "worker-child", tasks["T-1"]
    assert tasks["T-2"]["status"] == "pending" and tasks["T-2"]["ready"] is True, tasks["T-2"]
    assert tasks["T-2"]["blocked"] is False, tasks["T-2"]
PY
grep -q "team resumed ok" "$tmp_root/resume.jsonl"

# 4. Verify non-yolo default `auto` sandbox mode allows team_create/claim/update/complete/list
#    via the private host persistence worker even when MARE_HOME/state is outside the workspace.
cat >"$tmp_root/faux-auto.json" <<'JSON'
[
  {"tool_calls":[{"name":"team_create","arguments":{"title":"Auto sandbox task"}}]},
  {"tool_calls":[{"name":"team_claim","arguments":{"id":"T-1","owner":"auto-worker"}}]},
  {"tool_calls":[{"name":"team_update","arguments":{"id":"T-1","owner":"auto-worker","note":"halfway"}}]},
  {"tool_calls":[{"name":"team_complete","arguments":{"id":"T-1","owner":"auto-worker","result":"auto done"}}]},
  {"tool_calls":[{"name":"team_list","arguments":{}}]},
  {"text":"team auto sandbox ok"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-auto.json"
"$mare_bin" -C "$tmp_root/work" --permission auto --approval-policy never -p --json --session-id team-e2e-auto 'verify auto sandbox persistence' >"$tmp_root/auto.jsonl"
grep -q "team auto sandbox ok" "$tmp_root/auto.jsonl"
python3 - "$tmp_root/auto.jsonl" <<'PY'
import json, sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
items = [
    e["data"]["item"]
    for e in events
    if e.get("type") == "item/completed"
    and isinstance(e.get("data"), dict)
    and isinstance(e["data"].get("item"), dict)
    and str(e["data"]["item"].get("name", "")).startswith("team_")
]
assert len(items) == 5, items
for item in items:
    assert item["result_status"] == "success", item
tasks = items[-1]["message"]["details"]["tasks"]
assert len(tasks) == 1 and tasks[0]["status"] == "completed" and tasks[0]["result"] == "auto done", tasks
PY

printf 'mare-plugins: team E2E passed\n'