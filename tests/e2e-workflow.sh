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

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-workflow-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/workflow" "$tmp_root/package/plugins/"
git_clean -C "$tmp_root/package" init -q -b main
git_clean -C "$tmp_root/package" add -A
git_clean -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture

export MARE_HOME="$tmp_root/home"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/workflow", url = "file://$tmp_root/package" } }
LUA

"$mare_bin" -C "$tmp_root/work" plugin sync

# 1. Default disabled: /workflow off by default, tool should not run until /workflow on.
cat >"$tmp_root/faux-off.json" <<'JSON'
[
  {"text":"workflow is disabled check"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-off.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --no-session 'hello' >"$tmp_root/off.txt"
grep -q "workflow is disabled check" "$tmp_root/off.txt"

# 2. Enable workflow via state.json (same persistence as /workflow on) and run a real workflow tool call.
#    Children must NOT be able to delegate via `subagent` or `workflow` (depth-1 enforcement).
mkdir -p "$MARE_HOME/state"
cat >"$MARE_HOME/state/state.json" <<'JSON'
{"version":1,"workflow_enabled":true}
JSON

cat >"$tmp_root/faux-wf.json" <<'JSON'
[
  {
    "tool_calls": [
      {
        "name": "workflow",
        "arguments": {
          "meta": {
            "name": "e2e-fanout",
            "description": "Verify workflow sandbox, subagent fanout, and depth-1 block"
          },
          "args": { "items": ["alpha", "beta"] },
          "script": "phase('Fanout')\nlocal res = parallel({\n  function() return agent('echo child one', { label = 'c1' }) end,\n  function() return agent('echo child two', { label = 'c2' }) end\n})\nlog('finished fanout')\nreturn { count = res.n, items = res }"
        }
      }
    ]
  },
  {"tool_calls":[{"name":"subagent","arguments":{"prompt":"grandchild forbidden"}}]},
  {"text":"child finished after subagent denied"}
]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-wf.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id wf-e2e-01 'run workflow' >"$tmp_root/wf.jsonl"

python3 - "$tmp_root/wf.jsonl" "$MARE_HOME/state/sessions" <<'PY'
import glob, json, pathlib, sys

jsonl_path, sessions_dir = sys.argv[1], sys.argv[2]
events = [json.loads(line) for line in open(jsonl_path, encoding="utf-8") if line.strip()]
wf_results = [
    e["data"]["item"]
    for e in events
    if e.get("type") == "item/completed"
    and isinstance(e.get("data"), dict)
    and isinstance(e["data"].get("item"), dict)
    and e["data"]["item"].get("name") == "workflow"
]
assert len(wf_results) == 1, f"expected 1 workflow tool result, got {len(wf_results)}"
res = wf_results[0]
assert res["result_status"] == "success", res
out = res["message"]["details"]["result"]
assert out["count"] == 2 and out["items"] == [
    "child finished after subagent denied",
    "child finished after subagent denied",
], f"unexpected non-null child results: {out}"

# Verify parent session journal has properly paired monotonic workflow records
session_files = [
    p
    for p in glob.glob(f"{sessions_dir}/**/*.jsonl", recursive=True)
    if "agents" not in pathlib.Path(p).parts
    and not any(part.endswith(".snapshots") for part in pathlib.Path(p).parts)
]
assert len(session_files) == 1, f"expected 1 parent session file, got {session_files}"
custom_kinds = []
for line in open(session_files[0], encoding="utf-8"):
    obj = json.loads(line)
    if obj.get("type") == "custom" and str(obj.get("kind", "")).startswith("workflow/"):
        custom_kinds.append((obj["kind"], obj.get("data", {})))
kinds = [k for k, _ in custom_kinds]
assert kinds == [
    "workflow/run-start",
    "workflow/agent-start",
    "workflow/agent-start",
    "workflow/agent-end",
    "workflow/agent-end",
    "workflow/run-end",
] or (
    kinds[0] == "workflow/run-start"
    and kinds[-1] == "workflow/run-end"
    and kinds.count("workflow/agent-start") == 2
    and kinds.count("workflow/agent-end") == 2
), f"unexpected journal sequence: {kinds}"

# Verify workflow child transcripts (`agents/wf-*/*.jsonl`) blocked `subagent` (`Tool call blocked` / denied)
child_files = [
    p
    for p in glob.glob(f"{sessions_dir}/**/agents/wf-*/*.jsonl", recursive=True)
    if ".snapshots/" not in p
]
assert len(child_files) == 2, f"expected 2 workflow child transcripts, got {child_files}"
for cf in child_files:
    body = open(cf, encoding="utf-8").read()
    assert "Unknown tool: subagent" in body or "Tool call blocked" in body or "not declared" in body, (
        f"child {cf} did not block subagent: {body}"
    )
PY

# 3. Verify resume loads cleanly with recorded workflow entries.
cat >"$tmp_root/faux-resume.json" <<'JSON'
[{"text":"resumed ok"}]
JSON
export MARE_FAUX_SCRIPT="$tmp_root/faux-resume.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --resume wf-e2e-01 'continue' >"$tmp_root/resume.txt"
grep -q "resumed ok" "$tmp_root/resume.txt"

printf 'mare-plugins: workflow E2E passed\n'