#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-plan-mode-e2e.XXXXXX")"
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]] && [[ -n "${tmp_root:-}" ]] && [[ -d "$tmp_root" ]]; then
    printf 'plan-mode e2e failed (rc=%d), artifacts: %s\n' "$rc" "$tmp_root" >&2
    for f in "$tmp_root/gate-e2e.jsonl" "$tmp_root/gate-patch-e2e.jsonl"; do
      if [[ -s "$f" ]]; then
        printf -- '--- %s (item/completed tool_call) ---\n' "$f" >&2
        jq -c 'select(.type == "item/completed" and .data.item.type == "tool_call") | {call: .data.item.call, isError: (.data.item.message.isError // .data.item.message.is_error // .data.item.result.is_error), content: (.data.item.message.content // .data.item.result.content)}' "$f" >&2 || true
      fi
    done
  fi
  if [[ "${PLAN_KEEP_ARTIFACTS:-0}" == 1 ]] || [[ $rc -ne 0 ]]; then
    printf 'plan-mode artifacts: %s\n' "$tmp_root" >&2
  else
    rm -rf "$tmp_root"
  fi
  if [[ -n "${outside_dir:-}" ]] && [[ -d "$outside_dir" ]] && [[ $rc -eq 0 ]] && [[ "${PLAN_KEEP_ARTIFACTS:-0}" != 1 ]]; then
    rm -rf "$outside_dir"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config/plugins" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/plan-mode" "$tmp_root/package/plugins/"
cp -R "$repo_root/plugins/terminals" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/plan-mode-probe" "$tmp_root/package/plugins/"
git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
cat >"$tmp_root/home/config/plugins/g2-capture.lua" <<'LUA'
return {
	name = "g2-capture",
	inject = { "llm" },
	apply = function(ctx)
		ctx:on("request/build", function(req, ev)
			local path = mare.env.get("PLAN_EFFORT_CAPTURE")
			if not path or path == "" then
				return ev.next(req)
			end
			local f = io.open(path, "a")
			if f then
				f:write(
					mare.json.encode({
						model = req.model and req.model.ref or nil,
						effort = ctx.llm:effort(),
						active_scope = ctx.llm.active_scope and ctx.llm:active_scope() or nil,
					}) .. "\n"
				)
				f:close()
			end
			return ev.next(req)
		end)
	end,
}
LUA
export MARE_HOME="$tmp_root/home" PLAN_CAPTURE="$tmp_root/requests.jsonl" PLAN_EFFORT_CAPTURE="$tmp_root/effort.jsonl"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
printf '[{"text":"planned"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
PLAN_CONTRACTS=1 PLAN_REPORT="$tmp_root/contracts.json" "$mare_bin" -C "$tmp_root/work" -p --no-session 'probe public contracts' >"$tmp_root/contracts-run.txt"
jq -e '.ok == true and .detail == "passed"' "$tmp_root/contracts.json" >/dev/null || { cat "$tmp_root/contracts.json"; exit 1; }
jq -s -e 'length == 1 and (.[0].active | not) and (.[0].system | contains("Plan mode (soft guidance) is active") | not)' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" -p --json --session-id plan-e2e 'design the change' >"$tmp_root/run.jsonl"
jq -s -e 'length == 1 and .[0].active and (.[0].system | contains("Plan mode (soft guidance) is active")) and (.[0].tools | any(.[]; .name == "exit_plan_mode"))' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
"$mare_bin" -C "$tmp_root/work" -p --resume plan-e2e 'refine the design' >"$tmp_root/resume.txt"
jq -s -e 'length == 1 and .[0].active and (.[0].system | contains("Plan mode (soft guidance) is active"))' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
PLAN_ACTION=off "$mare_bin" -C "$tmp_root/work" -p --resume plan-e2e 'continue normally' >"$tmp_root/off.txt"
jq -s -e 'length == 1 and (.[0].active | not) and (.[0].system | contains("Plan mode (soft guidance) is active") | not)' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
"$mare_bin" -C "$tmp_root/work" -p --resume plan-e2e 'still normal' >"$tmp_root/off-resume.txt"
jq -s -e 'length == 1 and (.[0].active | not)' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" -p --no-session 'temporary planning' >"$tmp_root/ephemeral.txt"
jq -s -e 'length == 1 and .[0].active' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
"$mare_bin" -C "$tmp_root/work" -p --session-id plan-new 'new session' >"$tmp_root/new.txt"
jq -s -e 'length == 1 and (.[0].active | not) and (.[0].system | contains("Plan mode (soft guidance) is active") | not)' "$PLAN_CAPTURE" >/dev/null
: >"$PLAN_CAPTURE"
printf 'readable input' >"$tmp_root/work/input.txt"
printf '[{"tool_calls":[{"name":"read","arguments":{"path":"input.txt"}}]},{"text":"done"}]' >"$tmp_root/script.json"
PLAN_FREEZE_RACE=1 PLAN_TRANSFORM_CHAIN="$tmp_root/transform-chain.jsonl" "$mare_bin" -C "$tmp_root/work" --yolo -p --no-session 'frozen selection race' >"$tmp_root/frozen.txt"
# the probe's context/transform listener took (history, model, next) and the rest of the chain ran
jq -s -e 'length >= 1 and all(.[]; .history and .model and .returned)' "$tmp_root/transform-chain.jsonl" >/dev/null
jq -s -e 'length >= 2 and .[0].active and .[0].pending == false and (.[0].system | contains("Plan mode (soft guidance) is active")) and (.[1:] | all(.[]; (.active | not) and (.system | contains("Plan mode (soft guidance) is active") | not)))' "$PLAN_CAPTURE" >/dev/null

# Compare plan-only and global effort scopes, including a model without an effort parameter.
printf '[{"text":"ok"}]' >"$tmp_root/script.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
mare.plugin("plan-mode", { plan_effort = "high", effort_scope = "plan" })
LUA
: >"$PLAN_EFFORT_CAPTURE"
"$mare_bin" -C "$tmp_root/work" -p --session-id plan-g2-e2e 'baseline global effort' >"$tmp_root/g2-base.txt"
jq -s -e 'length == 1 and .[0].effort == "medium" and .[0].active_scope == null' "$PLAN_EFFORT_CAPTURE" >/dev/null
: >"$PLAN_EFFORT_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" -p --resume plan-g2-e2e 'plan effort active' >"$tmp_root/g2-on.txt"
jq -s -e 'length == 1 and .[0].effort == "high" and .[0].active_scope == "plan"' "$PLAN_EFFORT_CAPTURE" >/dev/null
: >"$PLAN_EFFORT_CAPTURE"
PLAN_ACTION=off "$mare_bin" -C "$tmp_root/work" -p --resume plan-g2-e2e 'plan effort restored' >"$tmp_root/g2-off.txt"
jq -s -e 'length == 1 and .[0].effort == "medium" and .[0].active_scope == null' "$PLAN_EFFORT_CAPTURE" >/dev/null

cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
mare.plugin("plan-mode", { plan_effort = "high", effort_scope = "global" })
LUA
: >"$PLAN_EFFORT_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" -p --session-id plan-g2-global 'global effort enter' >"$tmp_root/g2-gon.txt"
jq -s -e 'length == 1 and .[0].effort == "high" and .[0].active_scope == null' "$PLAN_EFFORT_CAPTURE" >/dev/null
: >"$PLAN_EFFORT_CAPTURE"
PLAN_ACTION=off "$mare_bin" -C "$tmp_root/work" -p --resume plan-g2-global 'global effort stays' >"$tmp_root/g2-goff.txt"
jq -s -e 'length == 1 and .[0].effort == "high" and .[0].active_scope == null' "$PLAN_EFFORT_CAPTURE" >/dev/null

cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo2" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
mare.plugin("plan-mode", { plan_effort = "high", effort_scope = "plan" })
LUA
: >"$PLAN_EFFORT_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" -p --no-session 'model without effort param' >"$tmp_root/g2-noeffort.txt"
jq -s -e 'length == 1 and .[0].model == "faux/echo2" and .[0].effort == null' "$PLAN_EFFORT_CAPTURE" >/dev/null

# Exercise tool execution, persistent allow rules, and unchanged files in the real runtime.
cat >"$MARE_HOME/config/plugins/gate-probe.lua" <<'LUA'
return {
	name = "gate-probe",
	inject = { "tools" },
	apply = function(ctx)
		ctx.tools:register("mcp_probe", {
			description = "Read-only unconfined probe tool",
			side_effect = "read",
			unconfined = true,
			parameters = { type = "object", properties = {} },
			execute = function()
				local marker = mare.env.get("PLAN_MCP_MARKER")
				if marker and marker ~= "" then
					mare.fs.write(marker, "ran")
				end
				return "ran"
			end,
		})
	end,
}
LUA
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
mare.plugin("permissions", {
	rules = {
		{ tool = "subagent", decision = "allow" },
		{ tool = "mcp_probe", decision = "allow" },
	},
})
LUA
printf 'original\n' >"$tmp_root/work/keep.txt"
outside_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-$HOME}/mare-plan-outside.XXXXXX")"
if command -v cygpath >/dev/null 2>&1; then
  outside_dir="$(cygpath -m "$outside_dir")"
fi
export PLAN_MCP_MARKER="$tmp_root/mcp-ran.txt"

tool_text_by_call() {
  local jsonl="$1" tool="$2" idx="$3"
  jq -s -c --arg tool "$tool" --argjson idx "$idx" '
    [ .[] | select(.type == "item/completed" and .data.item.type == "tool_call" and .data.item.name == $tool) ]
    | .[$idx]
    | {
        isError: (.data.item.message.isError == true or .data.item.message.is_error == true or .data.item.result.is_error == true),
        text: ([ (.data.item.message.content // .data.item.result.content)[]? | select(.type == "text") | .text ] | join("\n"))
      }
  ' "$jsonl"
}

assert_tool_result() {
  local jsonl="$1" tool="$2" idx="$3" needle="$4"
  local res
  res="$(tool_text_by_call "$jsonl" "$tool" "$idx")"
  jq -e --arg needle "$needle" '.isError == true and (.text | contains($needle))' <<<"$res" >/dev/null || {
    printf 'unexpected tool result for %s[%d]: %s (expected %q)\n' "$tool" "$idx" "$res" "$needle" >&2
    return 1
  }
}

shell_tool="bash"
shell_write_esc="touch '$outside_dir/esc-off.txt'"
shell_write_pos="touch pos-writable.txt"
shell_write_plan="touch bash-created.txt"
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*)
    shell_tool="powershell"
    shell_write_esc="Set-Content -Path '$outside_dir/esc-off.txt' -Value ok"
    shell_write_pos="Set-Content -Path pos-writable.txt -Value ok"
    shell_write_plan="Set-Content -Path bash-created.txt -Value ok"
    ;;
esac

# Positive baseline 1: escalation outside workspace/tmp enters normal approval when plan is OFF.
cat >"$tmp_root/script.json" <<JSON
[
  {
    "tool_calls": [
      { "name": "$shell_tool", "arguments": { "command": "$shell_write_esc", "sandbox_permissions": "write:$outside_dir", "justification": "probe escalation outside workspace" } }
    ]
  },
  { "text": "baseline-done" }
]
JSON
PLAN_ACTION=off "$mare_bin" -C "$tmp_root/work" -p --json --no-session 'positive escalation baseline with plan off' >"$tmp_root/gate-baseline.jsonl"
assert_tool_result "$tmp_root/gate-baseline.jsonl" "$shell_tool" 0 "approval was required but nobody can answer"
[[ ! -e "$outside_dir/esc-off.txt" ]]

# Compare the baseline and plan mode under identical config: only PLAN_ACTION differs.
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
mare.plugin("permissions", {
	preset = "auto",
	rules = {
		{ tool = "bash", decision = "allow" },
		{ tool = "powershell", decision = "allow" },
		{ tool = "subagent", decision = "allow" },
		{ tool = "mcp_probe", decision = "allow" },
	},
})
LUA
cat >"$tmp_root/script.json" <<JSON
[
  {
    "tool_calls": [
      { "name": "$shell_tool", "arguments": { "command": "$shell_write_pos" } }
    ]
  },
  { "text": "pos-write-done" }
]
JSON
PLAN_ACTION=off "$mare_bin" -C "$tmp_root/work" --trust -p --json --no-session 'positive writable bash baseline' >"$tmp_root/gate-pos-write.jsonl"
jq -e '.isError == false' <<<"$(tool_text_by_call "$tmp_root/gate-pos-write.jsonl" "$shell_tool" 0)" >/dev/null
[[ -f "$tmp_root/work/pos-writable.txt" ]]
rm -f "$tmp_root/work/pos-writable.txt"

cat >"$tmp_root/script.json" <<JSON
[
  {
    "tool_calls": [
      { "name": "write", "arguments": { "path": "new-write.txt", "content": "bad" } },
      { "name": "edit", "arguments": { "path": "keep.txt", "old_string": "original", "new_string": "mutated" } },
      { "name": "$shell_tool", "arguments": { "command": "$shell_write_plan" } },
      { "name": "$shell_tool", "arguments": { "command": "echo hi", "sandbox_permissions": "write:$outside_dir", "justification": "probe escalation in plan mode" } },
      { "name": "subagent", "arguments": { "prompt": "noop" } },
      { "name": "terminal_open", "arguments": { "name": "plan-term", "cwd": "." } },
      { "name": "mcp_probe", "arguments": {} }
    ]
  },
  { "text": "gate-done" }
]
JSON
: >"$PLAN_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" --trust -p --json --no-session 'exercise plan gate' >"$tmp_root/gate-e2e.jsonl"
jq -s -e --arg sh "$shell_tool" 'length >= 1 and .[0].active and (["write","edit",$sh,"subagent","terminal_open","mcp_probe"] as $req | (.[0].tools | map(.name)) as $decl | all($req[]; . as $t | ($decl | index($t)) != null))' "$PLAN_CAPTURE" >/dev/null
[[ ! -e "$tmp_root/work/new-write.txt" ]]
[[ ! -e "$tmp_root/work/bash-created.txt" ]]
[[ ! -e "$PLAN_MCP_MARKER" ]]
[[ "$(cat "$tmp_root/work/keep.txt")" == "original" ]]

assert_tool_result "$tmp_root/gate-e2e.jsonl" "write" 0 "Local writes are blocked in plan mode"
assert_tool_result "$tmp_root/gate-e2e.jsonl" "edit" 0 "Local writes are blocked in plan mode"
bash_write_res="$(tool_text_by_call "$tmp_root/gate-e2e.jsonl" "$shell_tool" 0)"
jq -e '.isError == true and (.text | contains("bash-created.txt")) and (.text | test("Read-only file system|Permission denied|Operation not permitted|Access.*denied|UnauthorizedAccess"; "i"))' <<<"$bash_write_res" >/dev/null || {
  printf 'unexpected bash write block result: %s\n' "$bash_write_res" >&2
  exit 1
}
jq -s -e --arg sh "$shell_tool" '[ .[] | select(.type == "item/completed" and .data.item.type == "tool_call" and .data.item.name == $sh) ][0].data.item.message.details.sandbox | .level == "read-only" and (.enforced | index("fs_write") != null)' "$tmp_root/gate-e2e.jsonl" >/dev/null
assert_tool_result "$tmp_root/gate-e2e.jsonl" "$shell_tool" 1 "Escalated permissions are unavailable in plan mode"
assert_tool_result "$tmp_root/gate-e2e.jsonl" "subagent" 0 "Subagents cannot be spawned or steered in plan mode"
assert_tool_result "$tmp_root/gate-e2e.jsonl" "terminal_open" 0 "terminal is unavailable in plan mode"
assert_tool_result "$tmp_root/gate-e2e.jsonl" "mcp_probe" 0 "approval was required but nobody can answer"

# Separate run for apply_patch edit_mode with valid `input` argument
cat >"$tmp_root/script.json" <<JSON
[
  {
    "tool_calls": [
      { "name": "apply_patch", "arguments": { "input": "*** Begin Patch\n*** Update File: keep.txt\n@@\n-original\n+patched\n*** End Patch" } }
    ]
  },
  { "text": "patch-done" }
]
JSON
: >"$PLAN_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" --trust --set plugins.tools.edit_mode=apply_patch -p --json --no-session 'exercise apply_patch plan gate' >"$tmp_root/gate-patch-e2e.jsonl"
jq -s -e 'length >= 1 and .[0].active and (.[0].tools | any(.[]; .name == "apply_patch"))' "$PLAN_CAPTURE" >/dev/null
[[ "$(cat "$tmp_root/work/keep.txt")" == "original" ]]
assert_tool_result "$tmp_root/gate-patch-e2e.jsonl" "apply_patch" 0 "Local writes are blocked in plan mode"

# Network is not part of the plugin's contribution: the vote-field unit
# tests in plan_gate_matrix_spec.lua prove plan leaves the network dimension to the session policy.

# Usage is optional: with the core usage plugin turned off, a session that
# had plan mode on is restored by plan-mode, and its write gate still holds (real loader, real host)
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
LUA
printf '[{"text":"planning without usage"}]' >"$tmp_root/script.json"
: >"$PLAN_CAPTURE"
PLAN_ACTION=on "$mare_bin" -C "$tmp_root/work" -p --json --session-id plan-no-usage 'turn plan mode on' >"$tmp_root/no-usage-on.jsonl"
jq -s -e 'length == 1 and .[0].active' "$PLAN_CAPTURE" >/dev/null
cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup { model = "faux/echo" }
mare.plugins.add { { "test/plan-mode", url = "file://$tmp_root/package" } }
mare.plugin("usage", { enabled = false })
LUA
cat >"$tmp_root/script.json" <<JSON
[
  { "tool_calls": [ { "name": "write", "arguments": { "path": "no-usage-write.txt", "content": "bad" } } ] },
  { "text": "no-usage-done" }
]
JSON
: >"$PLAN_CAPTURE"
"$mare_bin" -C "$tmp_root/work" --trust -p --json --resume plan-no-usage 'try to write without usage' >"$tmp_root/no-usage-resume.jsonl"
jq -s -e 'length >= 1 and .[0].active' "$PLAN_CAPTURE" >/dev/null
[[ ! -e "$tmp_root/work/no-usage-write.txt" ]]
assert_tool_result "$tmp_root/no-usage-resume.jsonl" "write" 0 "Local writes are blocked in plan mode"

printf 'mare-plugins: plan-mode file:// contracts, faux prompts, on/off resume, ephemeral state, effort scopes, tool policy and plan-mode without usage e2e passed\n'
