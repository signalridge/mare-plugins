#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:?Set MARE_BIN to the terminal support branch executable}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-terminal-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/terminals" "$repo_root/tests/fixtures/terminal-probe" "$repo_root/tests/fixtures/terminal-backend-owner" "$tmp_root/package/plugins/"
export MARE_HOME="$tmp_root/home"
cat > "$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugin("jobs", {notify_inline_bytes=0})
mare.plugins.add { { "test/terminal", url = "file://$tmp_root/package" } }
LUA
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"terminal probe complete"}]' > "$tmp_root/script.json"
if ! TERMINAL_PROBE_REPORT="$tmp_root/report.json" MARE_FAUX_SCRIPT="$tmp_root/script.json" \
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json --no-session 'probe terminal' > "$tmp_root/run.jsonl" 2> "$tmp_root/stderr"; then
    cat "$tmp_root/stderr" "$tmp_root/run.jsonl"
    [[ ! -f "$tmp_root/report.json" ]] || cat "$tmp_root/report.json"
    exit 1
fi
[[ -f "$tmp_root/report.json" ]] || { cat "$tmp_root/stderr"; exit 1; }
jq -e '.ok == true' "$tmp_root/report.json" >/dev/null || { cat "$tmp_root/report.json"; cat "$tmp_root/stderr"; exit 1; }
policies=(auto read-only)
if [[ ${TERMINAL_PROBE_POLICIES+x} ]]; then
    read -r -a policies <<< "$TERMINAL_PROBE_POLICIES"
fi
policy_extra_args=()
case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) policy_extra_args=(--set plugins.terminals.shell_dialect=pwsh) ;;
esac
for policy in "${policies[@]}"; do
    if ! TERMINAL_PROBE_POLICY="$policy" TERMINAL_PROBE_REPORT="$tmp_root/report-$policy.json" MARE_FAUX_SCRIPT="$tmp_root/script.json" \
        "$mare_bin" -C "$tmp_root/work" --permission "$policy" "${policy_extra_args[@]}" -p --json --no-session 'probe terminal policy' > "$tmp_root/policy.jsonl" 2> "$tmp_root/policy-stderr"; then
        cat "$tmp_root/policy-stderr" "$tmp_root/policy.jsonl"
        [[ ! -f "$tmp_root/report-$policy.json" ]] || cat "$tmp_root/report-$policy.json"
        exit 1
    fi
    jq -e '.ok == true' "$tmp_root/report-$policy.json" >/dev/null || { cat "$tmp_root/report-$policy.json"; exit 1; }
done
if ! TERMINAL_PROBE_SAVED=1 TERMINAL_PROBE_REPORT="$tmp_root/report-saved.json" MARE_FAUX_SCRIPT="$tmp_root/script.json" \
    "$mare_bin" -C "$tmp_root/work" --yolo -p --json 'probe terminal saved' > "$tmp_root/saved.jsonl" 2> "$tmp_root/saved-stderr"; then
    cat "$tmp_root/saved-stderr" "$tmp_root/saved.jsonl"
    [[ ! -f "$tmp_root/report-saved.json" ]] || cat "$tmp_root/report-saved.json"
    exit 1
fi
jq -e '.ok == true' "$tmp_root/report-saved.json" >/dev/null || { cat "$tmp_root/report-saved.json"; cat "$tmp_root/saved-stderr"; exit 1; }
printf 'terminal file:// faux, interactive TTY, safe output, jobs, cancellation, close, prompt and permission presets passed\n'
