#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then
	mare_bin="$(command -v "$mare_bin" || true)"
fi
[[ -n "$mare_bin" && -x "$mare_bin" ]] || {
	printf 'Set MARE_BIN to an existing mare executable (tried %s)\n' "$mare_bin" >&2
	exit 1
}

tmp_base="${MARE_TMPDIR:-${TMPDIR:-/tmp}}"
if command -v cygpath >/dev/null 2>&1; then
	case "$tmp_base" in
		*\\*) tmp_base="$(cygpath -u "$tmp_base")" ;;
	esac
fi
mkdir -p "$tmp_base"
tmp_root="$(mktemp -d "$tmp_base/mare-toolbelt-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work/src" "$tmp_root/work/scripts" "$tmp_root/work/nested" "$tmp_root/work/ignored_dir" "$tmp_root/work/docs"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/toolbelt" "$tmp_root/package/plugins/"

env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tmp_root/package" init -q -b main
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tmp_root/package" add -A
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tmp_root/package" \
	-c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false \
	commit -qm fixture

# Fixture workspace files
cat >"$tmp_root/work/.gitignore" <<'GITIGNORE'
ignored_dir/
GITIGNORE

cat >"$tmp_root/work/src/lib.rs" <<'RUST'
pub fn compute_answer(x: i32) -> i32 {
    x + 41
}
RUST

cat >"$tmp_root/work/scripts/app.py" <<'PY'
def py_target(value):
    return value * 2
PY

cat >"$tmp_root/work/nested/deep.rs" <<'RUST'
pub fn nested_marker() -> &'static str {
    "TOOLBELT_GREP_NEEDLE"
}
RUST

printf 'dash filename needle\n' >"$tmp_root/work/-dash-file.txt"
printf 'ignored secret needle\n' >"$tmp_root/work/ignored_dir/secret_ignored.txt"

python3 - "$tmp_root/work/docs/archive.zip" <<'PYZIP'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("guide.txt", "first line\ndoc_search_archive_needle\nlast line\n")
PYZIP

# Warm lazy aqua installation of rga before running timed checks.
if command -v rga >/dev/null 2>&1; then
	rga --version >/dev/null 2>&1 || true
fi

export MARE_HOME="$tmp_root/home"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/toolbelt", url = "file://$tmp_root/package" } }
LUA

"$mare_bin" -C "$tmp_root/work" plugin sync

skipped=0
missing_msg() {
	printf 'SKIPPED[capability=bin.%s] %s not found on PATH\n' "$1" "$1"
	skipped=1
}

has_rg=0; command -v rg >/dev/null 2>&1 && has_rg=1 || missing_msg rg
has_fd=0; command -v fd >/dev/null 2>&1 && has_fd=1 || missing_msg fd
has_ag=0
if command -v ast-grep >/dev/null 2>&1 || (command -v sg >/dev/null 2>&1 && sg --version 2>&1 | grep -qi 'ast-grep'); then
	has_ag=1
else
	missing_msg ast-grep
fi
has_rga=0; command -v rga >/dev/null 2>&1 && has_rga=1 || missing_msg rga

python3 - "$tmp_root/faux.json" "$has_rg" "$has_fd" "$has_ag" "$has_rga" <<'PYSCRIPT'
import json, sys
out_path, has_rg, has_fd, has_ag, has_rga = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
steps = []
if has_rg:
    steps.append({"tool_calls": [{"name": "grep", "arguments": {"pattern": "TOOLBELT_GREP_NEEDLE"}}]})
    steps.append({"tool_calls": [{"name": "grep", "arguments": {"pattern": "compute_answer", "output_mode": "files_with_matches"}}]})
    steps.append({"tool_calls": [{"name": "grep", "arguments": {"pattern": "dash filename needle", "path": "-dash-file.txt"}}]})
    steps.append({"tool_calls": [{"name": "grep", "arguments": {"pattern": "compute_answer", "path": "src/lib.rs", "output_mode": "count"}}]})
if has_fd:
    steps.append({"tool_calls": [{"name": "find", "arguments": {"pattern": "*.rs"}}]})
    steps.append({"tool_calls": [{"name": "find", "arguments": {"pattern": "*ignored*", "include_ignored": True}}]})
    steps.append({"tool_calls": [{"name": "find", "arguments": {"pattern": "./src/*.rs"}}]})
if has_ag:
    steps.append({"tool_calls": [{"name": "code_search", "arguments": {"pattern": "pub fn compute_answer($$$ARGS) -> $RET { $$$BODY }", "lang": "rust"}}]})
    steps.append({"tool_calls": [{"name": "code_search", "arguments": {"pattern": "def py_target($ARG): $$$BODY", "lang": "python"}}]})
if has_rga:
    steps.append({"tool_calls": [{"name": "doc_search", "arguments": {"pattern": "doc_search_archive_needle"}}]})
steps.append({"text": "toolbelt_e2e_done"})
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(steps, fh)
PYSCRIPT

export MARE_FAUX_SCRIPT="$tmp_root/faux.json"
"$mare_bin" -C "$tmp_root/work" --yolo -p --json --session-id toolbelt-e2e 'run toolbelt checks' >"$tmp_root/run.jsonl"

python3 - "$tmp_root/run.jsonl" "$has_rg" "$has_fd" "$has_ag" "$has_rga" <<'PYASSERT'
import json, sys

def msg_text(msg):
    c = (msg or {}).get("content")
    if isinstance(c, str):
        return c
    return "\n".join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")

path, has_rg, has_fd, has_ag, has_rga = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
results = {}
for line in open(path, encoding="utf-8"):
    if not line.strip().startswith("{"):
        continue
    ev = json.loads(line)
    if ev.get("type") == "item/completed":
        item = (ev.get("data") or {}).get("item") or {}
        if item.get("type") == "tool_call":
            name = item.get("name")
            results.setdefault(name, []).append(
                {"status": item.get("result_status"), "content": msg_text(item.get("message"))}
            )

if has_rg:
    rg_res = results.get("grep", [])
    assert len(rg_res) == 4, rg_res
    assert all(r["status"] == "success" for r in rg_res), rg_res
    assert "nested/deep.rs:2:" in rg_res[0]["content"], rg_res[0]
    assert "src/lib.rs" in rg_res[1]["content"], rg_res[1]
    assert "-dash-file.txt:1: dash filename needle" in rg_res[2]["content"], rg_res[2]
    assert "lib.rs: 1" in rg_res[3]["content"] and "total: 1" in rg_res[3]["content"], rg_res[3]

if has_fd:
    fd_res = results.get("find", [])
    assert len(fd_res) == 3, fd_res
    assert all(r["status"] == "success" for r in fd_res), fd_res
    assert "src/lib.rs" in fd_res[0]["content"] and "nested/deep.rs" in fd_res[0]["content"], fd_res[0]
    assert "ignored_dir/secret_ignored.txt" in fd_res[1]["content"], fd_res[1]
    assert "src/lib.rs" in fd_res[2]["content"] and "nested/deep.rs" not in fd_res[2]["content"], fd_res[2]

if has_ag:
    ag_res = results.get("code_search", [])
    assert len(ag_res) == 2 and all(r["status"] == "success" for r in ag_res), ag_res
    assert "src/lib.rs:1: pub fn compute_answer" in ag_res[0]["content"], ag_res[0]
    assert "scripts/app.py:1: def py_target" in ag_res[1]["content"], ag_res[1]

if has_rga:
    rga_res = results.get("doc_search", [])
    assert len(rga_res) == 1 and rga_res[0]["status"] == "success", rga_res
    assert "docs/archive.zip" in rga_res[0]["content"] and "guide.txt" in rga_res[0]["content"] and "doc_search_archive_needle" in rga_res[0]["content"], rga_res
PYASSERT

# Real cancellation test: hang a child process via wrapper rg binary on PATH, cancel via RPC, verify process tree exits.
mkdir -p "$tmp_root/cancel-bin" "$tmp_root/home-cancel/config"
cp "$MARE_HOME/config/init.lua" "$tmp_root/home-cancel/config/init.lua"
cat >"$tmp_root/cancel-bin/rg" <<'SH'
#!/usr/bin/env bash
sleep 60 &
child_pid=$!
printf '%s %s\n' "$$" "$child_pid" >"$TOOLBELT_CANCEL_PID_FILE"
touch "$TOOLBELT_CANCEL_READY_FILE"
wait "$child_pid"
SH
chmod +x "$tmp_root/cancel-bin/rg"
case "$(uname -s 2>/dev/null || true)" in
	MINGW*|MSYS*|CYGWIN*)
		cat >"$tmp_root/cancel-bin/rg-hang.py" <<'PY'
import os, pathlib, subprocess, sys
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
pathlib.Path(os.environ["TOOLBELT_CANCEL_PID_FILE"]).write_text(f"{os.getpid()} {child.pid}\n", encoding="utf-8")
pathlib.Path(os.environ["TOOLBELT_CANCEL_READY_FILE"]).write_text("ready\n", encoding="utf-8")
child.wait()
PY
		cat >"$tmp_root/cancel-bin/rg.cmd" <<'CMD'
@echo off
python3 "%~dp0rg-hang.py" %*
CMD
		;;
esac

printf '[{"tool_calls":[{"name":"grep","arguments":{"pattern":"hang"}}]},{"text":"after_cancel"}]\n' >"$tmp_root/cancel-faux.json"
MARE_HOME="$tmp_root/home-cancel" "$mare_bin" -C "$tmp_root/work" plugin sync

PATH="$tmp_root/cancel-bin:$PATH" \
MARE_HOME="$tmp_root/home-cancel" \
TOOLBELT_CANCEL_PID_FILE="$tmp_root/cancel.pid" \
TOOLBELT_CANCEL_READY_FILE="$tmp_root/cancel.ready" \
python3 "$repo_root/tests/e2e-toolbelt.py" \
	"$mare_bin" \
	"$tmp_root/work" \
	"$tmp_root/cancel-faux.json" \
	"$tmp_root/cancel.pid" \
	"$tmp_root/cancel.ready"

printf 'mare-plugins: toolbelt e2e (rg/fd/ast-grep/rga + RPC cancel process kill) passed\n'
[[ "$skipped" -eq 0 ]] || exit 77
