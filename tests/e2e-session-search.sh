#!/usr/bin/env bash
set -euo pipefail
# the fixture's MARE_HOME/state dirs must not be group-writable: core refuses a spill root with a
# group/world-writable ancestor (mare-binding spill/local.rs trusted_directory, "spill directory
# has an unsafe ancestor"); with umask 002 the directories this test creates would be 0775
# (same as e2e-spill.sh; the core question is in the backlog)
umask 022
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-session-search-e2e.XXXXXX")"
tmp_root="$(cd -- "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work" "$tmp_root/other"
printf 'name = "test/session-search"\n' > "$tmp_root/package/mare-plugin.toml"
cp -R "$repo_root/plugins/session-search" "$tmp_root/package/plugins/"
cp -R "$repo_root/plugins/tool-spill" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/session-search-probe" "$tmp_root/package/plugins/"
mkdir -p "$tmp_root/package/plugins/spill-e2e-probe"
cat > "$tmp_root/package/plugins/spill-e2e-probe/mare-plugin.toml" <<'TOML'
name = "spill-e2e-probe"
description = "Test probe for the read policy in session-search"
category = "tools"
TOML
cat > "$tmp_root/package/plugins/spill-e2e-probe/init.lua" <<'LUA'
return {
	name = "spill-e2e-probe",
	apply = function(ctx)
		ctx:on("app/ready", function()
			if mare.env("SEARCH_SPILL_DENY") == "1" then
				mare.proc.sandbox.set_current({
					level = "read-only",
					network = true,
					deny_read = { mare.paths.state .. "/spill-results" },
					accept_partial = { "fs_deny_read" },
				})
			end
		end)
	end,
}
LUA
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home"
export HISTORY_CAPTURE="$tmp_root/requests.jsonl"
export HISTORY_CHILD_REPORT="$tmp_root/child-report.json"
cat > "$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/session-search", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
# Seed sessions through the public session writer, then inject a foreign header into the same
# physical directory: scope must be checked against the observed snapshot, not its location.
printf '[{"text":"secret needle 世界"}]' > "$tmp_root/seed.json"
export MARE_FAUX_SCRIPT="$tmp_root/seed.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --session-id history-one 'seed' > /dev/null
python3 - "$MARE_HOME" > "$tmp_root/seed-path" <<'PY'
import json,pathlib,sys
home=pathlib.Path(sys.argv[1])
src=next(p for p in home.rglob('*.jsonl') if any(json.loads(l).get('session_id')=='history-one' for l in p.read_text(encoding="utf-8").splitlines() if l.startswith('{')))
rows=[json.loads(l) for l in src.read_text(encoding="utf-8").splitlines()]
seed_cwd=rows[0]['cwd']
rows=[rows[0]] + [{'type':'message','entry_id':f'm{i}','message':{'role':'assistant','content':[{'type':'text','text':'secret needle 世界'},{'type':'tool_call','name':'tool_only_needle'}]}} for i in range(1,126)]
src.write_text(''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in rows), encoding="utf-8")
rows[0]['session_id']='hidden'; rows[0]['cwd']='/unrelated-private-workspace'
src.with_name('hidden.jsonl').write_text(''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in rows), encoding="utf-8")
rows[0]['session_id']='history-archived'; rows[0]['cwd']=seed_cwd
rows += [{'type':'archive','archived':True},{'type':'name','name':'Archived evidence'}]
src.with_name('archived.jsonl').write_text(''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in rows), encoding="utf-8")
big_e2e = 'E' * 70000
surf_rows = [
    {'type':'session','version':3,'session_id':'surface-e2e','cwd':seed_cwd,'created_at_ms':100},
    {'type':'name','name':'Surface E2E'},
    {'type':'message','entry_id':'su1','created_at_ms':110,'message':{'role':'user','content':'e2e_surface_needle shadowed'}},
    {'type':'compaction','entry_id':'scmp1','parent_entry_id':'su1','created_at_ms':120,'summary':'compacted e2e'},
    {'type':'message','entry_id':'su2','parent_entry_id':'scmp1','created_at_ms':130,'message':{'role':'assistant','content':f'e2e_oversize_needle {big_e2e}'}},
]
src.with_name('surface-e2e.jsonl').write_text(''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in surf_rows), encoding="utf-8")
print(src)
PY
read -r HISTORY_SEED_PATH < "$tmp_root/seed-path"
HISTORY_SEED_PATH="${HISTORY_SEED_PATH%$'\r'}"
export HISTORY_SEED_PATH
printf '[{"tool_calls":[{"name":"history_probe","arguments":{}}]},{"text":"probed"}]' > "$tmp_root/probe.json"
export MARE_FAUX_SCRIPT="$tmp_root/probe.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id history-current 'retrieve history' > "$tmp_root/result.jsonl"
jq -s -e 'tostring | contains("history-probe-passed")' "$tmp_root/result.jsonl" >/dev/null
python3 - "$tmp_root/result.jsonl" "$tmp_root/tools.json" <<'PYTOOLS'
import json,re,sys
source=open(sys.argv[1], encoding="utf-8").read()
event_id=re.search(r'EVENT:([A-Za-z0-9_-]+)',source).group(1)
script=[{"tool_calls":[{"name":"session_search","arguments":{"query":"secret needle"}}]},
 {"tool_calls":[{"name":"session_search","arguments":{"query":"secret needle","archived":True}}]},
 {"tool_calls":[{"name":"session_search","arguments":{"title_query":"Surface","sort_key":"updated_at_ms","sort_direction":"desc"}}]},
 {"tool_calls":[{"name":"session_trace","arguments":{"session_id":"history-one"}}]},
 {"tool_calls":[{"name":"session_event_trace","arguments":{"session_id":"surface-e2e","seq":2}}]},
 {"tool_calls":[{"name":"session_event_search","arguments":{"session_id":"surface-e2e","query":"e2e_oversize_needle","surfaces":["current"]}}]},
 {"tool_calls":[{"name":"session_event_search","arguments":{"session_id":"history-one","query":"secret needle"}}]},
 {"tool_calls":[{"name":"session_event_search","arguments":{"session_id":"history-one","query":"secret needle","seq_from":121,"seq_to":125}}]},
 {"tool_calls":[{"name":"session_event_search","arguments":{"session_id":"history-one","query":"needle","seq_from":10,"seq_to":1}}]},
 {"tool_calls":[{"name":"session_search","arguments":{"query":"   ","title_query":"Surface"}}]},
 {"tool_calls":[{"name":"session_event_read","arguments":{"event_id":event_id,"before":11}}]},
 {"tool_calls":[{"name":"session_event_trace","arguments":{"session_id":"surface-e2e","seq":0}}]},
 {"tool_calls":[{"name":"session_event_read","arguments":{"event_id":event_id,"before":1,"after":1}}]},
 {"text":"e2e_turn1_live_marker"}]
open(sys.argv[2],"w", encoding="utf-8").write(json.dumps(script))
PYTOOLS
export MARE_FAUX_SCRIPT="$tmp_root/tools.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id history-tools 'retrieve evidence' > "$tmp_root/tools-result.jsonl"
jq -s -e 'tostring | contains("secret needle 世界") and contains("neighbors")' "$tmp_root/tools-result.jsonl" >/dev/null
jq -s -e '[.. | objects | select(has("data")) | select(.capped == true) | .data | length] | index(100) != null' "$tmp_root/tools-result.jsonl" >/dev/null
jq -s -e '.[-1].tools | ([.[] | select(.name == "session_search" or .name == "session_event_search" or .name == "session_event_read" or .name == "session_trace" or .name == "session_event_trace")] | length == 5) and (all(.[] | select(.name | startswith("session_")); (.parameters.properties | has("cursor") or has("limit") or has("cwd")) | not))' "$HISTORY_CAPTURE" >/dev/null
jq -s -e 'tostring | contains("QUERY_INVALID_FILTER") and contains("QUERY_INVALID_QUERY") and contains("QUERY_INVALID_WINDOW") and contains("history-archived") and contains("Surface E2E") and contains("\"surface\":\"shadowed\"") and contains("\"replaced_by\":3")' "$tmp_root/tools-result.jsonl" >/dev/null
jq -s -e 'any(.. | objects; .metadata_only == true and .target.session_id == "history-one")' "$tmp_root/tools-result.jsonl" >/dev/null
python3 - "$tmp_root/tools-result.jsonl" <<'PYCHECK'
import json,re,sys
def msg_text(msg):
    c = (msg or {}).get("content")
    if isinstance(c, str):
        return c
    return "\n".join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
lines = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip().startswith("{")]
ev_read_contents = [
    msg_text(o["data"]["item"].get("message"))
    for o in lines
    if o.get("type") == "item/completed"
    and o.get("data", {}).get("item", {}).get("type") == "tool_call"
    and o.get("data", {}).get("item", {}).get("name") == "session_event_read"
    and o.get("data", {}).get("item", {}).get("result_status") == "success"
]
assert ev_read_contents and any(re.search(r"Neighbor seq \d+ · [A-Za-z0-9_-]+ \|", c) for c in ev_read_contents), ev_read_contents
err_contents = [
    msg_text(o["data"]["item"].get("message"))
    for o in lines
    if o.get("type") == "item/completed"
    and o.get("data", {}).get("item", {}).get("type") == "tool_call"
    and o.get("data", {}).get("item", {}).get("result_status") == "error"
]
assert len(err_contents) >= 4 and all(".lua:" not in c for c in err_contents), err_contents
PYCHECK
python3 - "$tmp_root/tools-result.jsonl" "$tmp_root/resume.json" <<'PYOVERSIZE'
import json,sys
hits=[]
def walk(x):
    if isinstance(x, dict):
        if x.get("session_id") == "surface-e2e" and "event_id" in x and "position" in x:
            hits.append(x["event_id"])
        for v in x.values():
            walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip().startswith("{"):
        walk(json.loads(line))
assert hits, open(sys.argv[1], encoding="utf-8").read()
big_eid=hits[0]
script=[
    {"tool_calls":[{"name":"session_event_read","arguments":{"event_id":big_eid}}]},
    {"tool_calls":[{"name":"session_event_search","arguments":{"query":"e2e_turn1_live_marker"}}]},
    {"tool_calls":[{"name":"session_event_search","arguments":{"query":"e2e_turn2_current_step_secret"}}],"text":"e2e_turn2_current_step_secret"},
    {"tool_calls":[{"name":"session_event_search","arguments":{"session_id":"history-one","query":"SECRET  NEEDLE","seq_from":121,"seq_to":125}}]},
    {"text":"restored evidence"},
]
open(sys.argv[2],"w", encoding="utf-8").write(json.dumps(script))
PYOVERSIZE
export MARE_FAUX_SCRIPT="$tmp_root/resume.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --resume history-tools 'continue checking prior evidence' > "$tmp_root/resume-result.jsonl"
jq -s -e 'tostring | contains("restored evidence") and contains("secret needle") and contains("\"spilled\":true") and contains("e2e_turn1_live_marker")' "$tmp_root/resume-result.jsonl" >/dev/null
jq -s -e '.[-1].session.session_id == "history-tools" and (.[-1].messages | tostring | contains("QUERY_INVALID_FILTER"))' "$HISTORY_CAPTURE" >/dev/null
python3 - "$tmp_root/resume-result.jsonl" "$tmp_root/read-spill-p1.json" "$tmp_root/cross-read.json" "$tmp_root/big-handle" <<'PYSPILL'
import json,sys
raw=open(sys.argv[1], encoding="utf-8").read()
assert "spill_path" not in raw, raw
big_handle = None
saw_turn1_hit = False
saw_step_bound_search = False
for line in raw.splitlines():
    if not line.strip().startswith("{"):
        continue
    obj = json.loads(line)
    if obj.get("type") == "item/completed" and (obj.get("data") or {}).get("item", {}).get("type") == "tool_call":
        item = obj["data"]["item"]
        name = item.get("name")
        args = item.get("arguments") or {}
        msg = item.get("message") or {}
        details = msg.get("details") or {}
        if name == "session_event_read" and details.get("spilled") is True:
            assert item.get("result_status") == "success", obj
            assert details.get("backend") == "local", details
            assert details.get("retrieval_hint"), details
            big_handle = details.get("handle")
        elif name == "session_event_search":
            hits = details.get("data", [])
            if args.get("query") == "e2e_turn1_live_marker":
                saw_turn1_hit = any("e2e_turn1_live_marker" in h.get("snippet", "") for h in hits)
            if args.get("query") == "e2e_turn2_current_step_secret":
                saw_step_bound_search = True
                assert not hits, obj
# mare.spill handles are opaque ids (no backend prefix)
assert isinstance(big_handle, str) and big_handle and "/" not in big_handle, raw
assert saw_turn1_hit and saw_step_bound_search, raw
open(sys.argv[4], "w", encoding="utf-8").write(big_handle + "\n")
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps([
    {"tool_calls":[{"name":"read_spill","arguments":{"handle":big_handle,"offset":1,"limit":100}}]},
    {"text":"page1_ok"},
]))
open(sys.argv[3], "w", encoding="utf-8").write(json.dumps([
    {"tool_calls":[{"name":"read_spill","arguments":{"handle":big_handle}}]},
    {"text":"cross_checked"},
]))
PYSPILL
# Dedicated fresh session exercises session_event_read spill -> multi-page read_spill retrieval without hitting context compaction
python3 - "$tmp_root/resume.json" "$tmp_root/spill-fresh.json" <<'PYFRESH'
import json,sys
s = json.loads(open(sys.argv[1], encoding="utf-8").read())
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps([s[0], {"text":"fresh_spilled"}]))
PYFRESH
export MARE_FAUX_SCRIPT="$tmp_root/spill-fresh.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id history-spill-e2e 'spill big event' > "$tmp_root/fresh-spill-result.jsonl"
python3 - "$tmp_root/fresh-spill-result.jsonl" "$tmp_root/read-spill-p1.json" "$tmp_root/fresh-handle" <<'PYFRESHHANDLE'
import json,sys
lines = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip().startswith("{")]
item = next(
    (
        o["data"]["item"]
        for o in lines
        if o.get("type") == "item/completed"
        and (o.get("data") or {}).get("item", {}).get("type") == "tool_call"
        and o["data"]["item"]["name"] == "session_event_read"
    ),
    None,
)
assert item is not None and item.get("result_status") == "success", open(sys.argv[1], encoding="utf-8").read()
h = item["message"]["details"]["handle"]
open(sys.argv[3], "w", encoding="utf-8").write(h + "\n")
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps([
    {"tool_calls":[{"name":"read_spill","arguments":{"handle":h,"offset":1,"limit":100}}]},
    {"text":"page1_ok"},
]))
PYFRESHHANDLE
read -r FRESH_HANDLE < "$tmp_root/fresh-handle"
FRESH_HANDLE="${FRESH_HANDLE%$'\r'}"
export MARE_FAUX_SCRIPT="$tmp_root/read-spill-p1.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --resume history-spill-e2e 'read spilled page 1' > "$tmp_root/read-spill-p1-result.jsonl"
python3 - "$tmp_root/read-spill-p1-result.jsonl" "$tmp_root/read-spill-p2.json" "$FRESH_HANDLE" <<'PYPAGE2'
import json,re,sys
def msg_text(msg):
    c = (msg or {}).get("content")
    if isinstance(c, str):
        return c
    return "\n".join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
lines = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip().startswith("{")]
page1 = next(
    (
        o["data"]["item"]
        for o in lines
        if o.get("type") == "item/completed"
        and (o.get("data") or {}).get("item", {}).get("type") == "tool_call"
        and o["data"]["item"]["name"] == "read_spill"
    ),
    None,
)
assert page1 is not None and page1.get("result_status") == "success", open(sys.argv[1], encoding="utf-8").read()
text1 = msg_text(page1.get("message"))
assert "e2e_oversize_needle" in text1 and text1.count("E") > 10000, text1[:200]
m = re.search(r"continue with cursor=(\d+)", text1)
assert m, text1[-200:]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps([
    {"tool_calls":[{"name":"read_spill","arguments":{"handle":sys.argv[3],"cursor":int(m.group(1)),"offset":1,"limit":100}}]},
    {"text":"page2_ok"},
]))
PYPAGE2
export MARE_FAUX_SCRIPT="$tmp_root/read-spill-p2.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --resume history-spill-e2e 'read spilled page 2' > "$tmp_root/read-spill-p2-result.jsonl"
python3 - "$tmp_root/read-spill-p1-result.jsonl" "$tmp_root/read-spill-p2-result.jsonl" <<'PYFULL'
import json,sys
def msg_text(msg):
    c = (msg or {}).get("content")
    if isinstance(c, str):
        return c
    return "\n".join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
def read_spill_text(path):
    lines = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip().startswith("{")]
    item = next(
        (
            o["data"]["item"]
            for o in lines
            if o.get("type") == "item/completed"
            and (o.get("data") or {}).get("item", {}).get("type") == "tool_call"
            and o["data"]["item"]["name"] == "read_spill"
        ),
        None,
    )
    assert item is not None and item.get("result_status") == "success", open(path, encoding="utf-8").read()
    return msg_text(item.get("message"))
p1 = read_spill_text(sys.argv[1]).split("\n[more output remains", 1)[0]
p2 = read_spill_text(sys.argv[2])
assert "more output remains" not in p2, p2[-200:]
assert (p1 + p2).count("E") == 70000, (p1.count("E"), p2.count("E"))
PYFULL
# Cross-session access rejection: another session cannot read history-tools' handle
export MARE_FAUX_SCRIPT="$tmp_root/cross-read.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id other-session-read 'cross read' > "$tmp_root/cross-result.jsonl"
jq -s -e 'any(.. | objects; .type == "item/completed" and .data.item.type == "tool_call" and .data.item.name == "read_spill" and .data.item.result.is_error == true)' "$tmp_root/cross-result.jsonl" >/dev/null
# Restricted read policy (deny_read on recovery storage) refuses spill with QUERY_UNAUTHORIZED
python3 - "$tmp_root/resume.json" "$tmp_root/deny-spill.json" <<'PYDENY'
import json,sys
s = json.loads(open(sys.argv[1], encoding="utf-8").read())
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps([s[0], {"text":"deny_checked"}]))
PYDENY
export MARE_FAUX_SCRIPT="$tmp_root/deny-spill.json"
SEARCH_SPILL_DENY=1 "$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id history-deny-spill 'deny spill' > "$tmp_root/deny-spill-result.jsonl"
jq -s -e 'any(.. | objects; .type == "item/completed" and .data.item.type == "tool_call" and .data.item.name == "session_event_read" and .data.item.result.is_error == true and .data.item.result.error_code == "QUERY_UNAUTHORIZED")' "$tmp_root/deny-spill-result.jsonl" >/dev/null
# A configured non-local backend is refused: session-search stores through core mare.spill since
# 4f57d43 and only the local store exists (custom ctx.output backends are gone). Mid-save
# cancellation and the refusal are also covered in session_search_spec.lua.
cp "$MARE_HOME/config/init.lua" "$tmp_root/orig-init.lua"
cat >> "$MARE_HOME/config/init.lua" <<'LUA'
mare.plugin("session-search", { backend = "e2e-custom" })
LUA
export MARE_FAUX_SCRIPT="$tmp_root/deny-spill.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id history-custom-backend 'custom backend' > "$tmp_root/custom-result.jsonl"
jq -s -e 'any(.. | objects; .type == "item/completed" and .data.item.type == "tool_call" and .data.item.name == "session_event_read" and .data.item.result.is_error == true and .data.item.result.error_code == "QUERY_CAPABILITY_UNAVAILABLE")' "$tmp_root/custom-result.jsonl" >/dev/null
cp "$tmp_root/orig-init.lua" "$MARE_HOME/config/init.lua"
export MARE_FAUX_SCRIPT="$tmp_root/resume.json"
# child caller identity first, so no later failure hides it (it adds one child under history-tools)
had_skip=0
MARE_BIN="$mare_bin" python3 "$repo_root/tests/session-search-child-identity.py" "$tmp_root/work"
ui_rc=0
MARE_BIN="$mare_bin" python3 "$repo_root/tests/session-search-ui.py" "$tmp_root/work" "$tmp_root/ui.json" || ui_rc=$?
if [[ "$ui_rc" -eq 77 ]]; then
	had_skip=1
elif [[ "$ui_rc" -ne 0 ]]; then
	exit "$ui_rc"
fi
MARE_BIN="$mare_bin" python3 "$repo_root/tests/session-search-rpc.py" "$tmp_root/work" "$HISTORY_SEED_PATH"
python3 - "$HISTORY_SEED_PATH" "$tmp_root/bulk.json" <<'PYBULK'
import gzip,json,pathlib,sys
seed_path = pathlib.Path(sys.argv[1])
sessions_dir = seed_path.parent
work = json.loads(seed_path.read_text(encoding="utf-8").splitlines()[0])["cwd"]
filler_line = json.dumps({"type":"message","entry_id":"f","created_at_ms":100,"message":{"role":"assistant","content":"B"*600000}}) + "\n"
for idx in range(6):
    hdr = json.dumps({"type":"session","version":3,"session_id":f"model-bulk-{idx}","cwd":work,"created_at_ms":100+idx}) + "\n"
    (sessions_dir / f"00-model-bulk-{idx}.jsonl").write_text(hdr + filler_line * 10, encoding="utf-8")
gz_rows = [
    {"type":"session","version":3,"session_id":"zz-model-tail","cwd":work,"created_at_ms":500},
    {"type":"name","name":"Model Tail Gzip"},
    {"type":"message","entry_id":"mt1","created_at_ms":5000,"message":{"role":"assistant","content":"model_tail_gz_needle"}},
]
(sessions_dir / "zz-model-tail.jsonl.gz").write_bytes(gzip.compress("".join(json.dumps(r)+"\n" for r in gz_rows).encode("utf-8")))
script = [
    {"tool_calls":[{"name":"session_search","arguments":{"query":"model_tail_gz_needle"}}]},
    {"text":"model_tail_done"},
]
pathlib.Path(sys.argv[2]).write_text(json.dumps(script), encoding="utf-8")
PYBULK
export MARE_FAUX_SCRIPT="$tmp_root/bulk.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id history-bulk 'find tail needle' > "$tmp_root/bulk-result.jsonl"
jq -s -e 'tostring | contains("zz-model-tail") and contains("model_tail_gz_needle")' "$tmp_root/bulk-result.jsonl" >/dev/null
printf 'mare-plugins: session-search file:// faux + RPC search/events/read, positions, cursors, neighbors, stale and policy passed\n'
[[ "$had_skip" -eq 0 ]] || exit 77
