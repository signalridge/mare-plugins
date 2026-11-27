#!/usr/bin/env bash
set -euo pipefail
if ! command -v rg >/dev/null 2>&1; then rg() { grep -E "$@"; }; fi
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || { printf 'Set MARE_BIN to an existing mare executable\n' >&2; exit 1; }
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-presets-e2e.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/presets" "$tmp_root/package/plugins/"
cp -R "$repo_root/tests/fixtures/presets-probe" "$tmp_root/package/plugins/"
mkdir -p "$tmp_root/package/plugins/presets-e2e-driver"
cat >"$tmp_root/package/plugins/presets-e2e-driver/init.lua" <<'LUA'
return {
	name = "presets-e2e-driver",
	inject = { "presets" },
	apply = function(ctx)
		ctx:on("app/ready", function()
			local set_def = mare.env("PRESETS_DRIVER_SET_DEFAULT")
			if set_def then
				assert(ctx.presets:set_default(set_def ~= "clear" and set_def or nil))
			end
			local stage_id = mare.env("PRESETS_DRIVER_STAGE")
			if stage_id then
				assert(ctx.presets:stage(stage_id ~= "clear" and stage_id or nil))
			end
		end)
	end,
}
LUA
# the fixture's git never inherits a caller's GIT_DIR / GIT_WORK_TREE (e.g. `git bisect run`)
fixture_git() { env $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/-u \1/p') git "$@"; }
fixture_git -C "$tmp_root/package" init -q -b main
fixture_git -C "$tmp_root/package" add -A
fixture_git -C "$tmp_root/package" -c user.name='mare test' -c user.email='test@example.invalid' -c commit.gpgsign=false commit -qm fixture
export MARE_HOME="$tmp_root/home" PRESETS_CAPTURE="$tmp_root/requests.jsonl" PRESETS_ENTRIES="$tmp_root/entries.json"
cat >"$MARE_HOME/config/init.lua" <<LUA
local setup = { fallback_models = { "presets-faux/fallback" } }
if mare.env("PRESETS_USE_SAVED") ~= "yes" then setup.model = "presets-faux/echo" end
mare.setup(setup)
mare.model { provider = "presets-faux", id = "selected", alias = "preset-high", params = { effort = "high" } }
if mare.env("PRESETS_HAS_RECOVERABLE") == "yes" then
  mare.model { provider = "presets-faux", id = "selected", alias = "preset-recoverable", params = { effort = "high" } }
end
local cfg_default = mare.env("PRESETS_CFG_DEFAULT")
mare.plugins.add {
  { "test/presets", url = "file://$tmp_root/package", opts = {
    presets = { default = cfg_default, definitions = {
      review = { system = "PRESET_GUIDANCE {{literal}}", tools = { "read" }, default = mare.env("PRESETS_DEFAULT") == "yes" },
      none = { tools = {} },
      selected = { model = "preset-high", system = "MODEL_GUIDANCE", tools = { "read" } },
      recoverable = { model = "preset-recoverable", system = "RECOVERED_GUIDANCE", tools = { "read" } },
      persona = { prefix = "PERSONA_PREFIX {{model}}", suffix = "PERSONA_SUFFIX", includeRuntimeContext = false, denylist = { "write" } },
      complete_persona = { prefix = "COMPLETE_PERSONA {{model}}", complete = true },
      bad_persona = { prefix = "BAD {{missing_var}}" },
      invalid_model = { model = "missing-presets-provider/does-not-exist" },
      broken = { model = false },
    } },
  } },
}
LUA
"$mare_bin" -C "$tmp_root/work" plugin sync
PRESETS_CAPS="$tmp_root/caps.json" "$mare_bin" -C "$tmp_root/work" doctor >/dev/null 2>&1 || true
[[ -s "$tmp_root/caps.json" ]] || { printf 'presets probe did not record the context capabilities\n' >&2; exit 1; }
jq -e 'all(.[]; . == true)' "$tmp_root/caps.json" >/dev/null \
  || { cat "$tmp_root/caps.json" >&2; exit 1; }
printf '[{"error":"unknown model","kind":"model_not_found","retryable":false},{"text":"fallback response"}]' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"
PRESETS_ACTION=review PRESETS_BUSY=yes "$mare_bin" -C "$tmp_root/work" -p --session-id presets-e2e 'real user input' >"$tmp_root/run.txt"
jq -s -e 'length == 2 and .[0].model == "presets-faux/echo" and .[1].model == "presets-faux/fallback" and all(.[]; .tools == ["read"] and (.system | contains("PRESET_GUIDANCE {{literal}}")) and .messages == (.history | map(del(.turn_id))))' "$PRESETS_CAPTURE" >/dev/null
jq -e '[.[] | select(.type == "custom" and ((.kind // "") | startswith("presets/")))] | length == 0' "$PRESETS_ENTRIES" >/dev/null
: >"$PRESETS_CAPTURE"
printf '[{"text":"normal response"}]' >"$tmp_root/script.json"
"$mare_bin" -C "$tmp_root/work" -p --resume presets-e2e 'normal after restart' >"$tmp_root/resume.txt"
jq -s -e 'length == 1 and (.[0].system | contains("PRESET_GUIDANCE") | not) and (.[0].tools | length > 1)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=none "$mare_bin" -C "$tmp_root/work" -p --no-session 'no tools requested' >"$tmp_root/none.txt"
jq -s -e 'length == 1 and .[0].tool_count == 0' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=review PRESETS_COMPLETE=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'complete system' >"$tmp_root/complete.txt"
jq -s -e 'length == 1 and .[0].system == "Complete replacement" and (.[0].tools | length > 1)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=selected "$mare_bin" -C "$tmp_root/work" -p --no-session 'chosen alias' >"$tmp_root/model.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].effort == "high" and .[0].current_model == "presets-faux/selected" and .[0].tools == ["read"] and (.[0].system | contains("MODEL_GUIDANCE"))' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=selected PRESETS_CLEAR=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'clear keeps model' >"$tmp_root/clear.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].effort == "high" and .[0].current_model == "presets-faux/selected" and (.[0].tools | length > 1) and (.[0].system | contains("MODEL_GUIDANCE") | not)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
# No model in init.lua for this fresh process: observe ordinary saved-default behavior
# through a real request and the public current() service, never private state fields.
PRESETS_USE_SAVED=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'saved model after restart' >"$tmp_root/saved.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].current_model == "presets-faux/selected" and (.[0].tools | length > 1) and (.[0].system | contains("MODEL_GUIDANCE") | not)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=invalid_model "$mare_bin" -C "$tmp_root/work" -p --no-session 'invalid model selection' >"$tmp_root/invalid.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/echo" and (.[0].tools | length > 1) and (.[0].system | contains("MODEL_GUIDANCE") | not)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=persona "$mare_bin" -C "$tmp_root/work" -p --no-session 'persona prefix suffix runtime suppress and denylist' >"$tmp_root/persona.txt"
jq -s -e 'length == 1 and (.[0].system | contains("PERSONA_PREFIX echo")) and (.[0].system | contains("PERSONA_SUFFIX")) and (.[0].system | contains("<environment>") | not) and (.[0].tools | index("write") | not)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=persona PRESETS_CLEAR=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'clear disposes persona sections and runtime suppressor' >"$tmp_root/persona_clear.txt"
jq -s -e 'length == 1 and (.[0].system | contains("PERSONA_PREFIX") | not) and (.[0].system | contains("PERSONA_SUFFIX") | not) and (.[0].tools | index("write") != null)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=complete_persona "$mare_bin" -C "$tmp_root/work" -p --no-session 'complete persona' >"$tmp_root/complete_persona.txt"
jq -s -e 'length == 1 and .[0].system == "COMPLETE_PERSONA echo"' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=complete_persona PRESETS_COMPLETE=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'complete conflict' >"$tmp_root/complete_conflict.txt"
jq -s -e 'length == 1 and .[0].system == "Complete replacement"' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_ACTION=bad_persona "$mare_bin" -C "$tmp_root/work" -p --no-session 'unknown template variable' >"$tmp_root/bad_persona.txt"
jq -s -e 'length == 1 and (.[0].system | contains("BAD") | not)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
printf 'allowed read contents\n' >"$tmp_root/work/allowed.txt"
printf '[{"tool_calls":[{"name":"read","arguments":{"path":"allowed.txt"}}]},{"tool_calls":[{"name":"write","arguments":{"path":"forbidden.txt","content":"must not write"}}]},{"text":"strict tool check complete"}]' >"$tmp_root/script.json"
PRESETS_ACTION=review PRESETS_READD=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'exercise allowed and forbidden tools' >"$tmp_root/strict.txt"
[[ ! -e "$tmp_root/work/forbidden.txt" ]]
jq -s -e 'length == 3 and all(.[]; .tools == ["read"]) and (.[2].messages | tostring | contains("not declared")) and (.[1].messages | tostring | contains("allowed read contents"))' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
if PRESETS_BAD_CONSTRAINT=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'constraint failure' >"$tmp_root/failure.txt" 2>&1; then
  printf 'failed tool constraint unexpectedly accepted\n' >&2
  exit 1
fi
[[ ! -s "$PRESETS_CAPTURE" ]]
rg -q 'fixture tool constraint failed' "$tmp_root/failure.txt"
: >"$PRESETS_CAPTURE"
printf '[{"text":"default startup response"}]' >"$tmp_root/script.json"
PRESETS_DEFAULT=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'default preset auto-applies on fresh startup' >"$tmp_root/default_startup.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/echo" and .[0].tools == ["read"] and (.[0].system | contains("PRESET_GUIDANCE {{literal}}"))' "$PRESETS_CAPTURE" >/dev/null
PRESETS_DEFAULT=yes python3 "$repo_root/tests/presets-rpc.py" "$mare_bin" "$tmp_root/work"
: >"$PRESETS_CAPTURE"
printf '[{"text":"persisted default response"}]' >"$tmp_root/script.json"
PRESETS_DEFAULT=yes PRESETS_USE_SAVED=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'persisted set_default survives restart' >"$tmp_root/persisted_default.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].effort == "high" and .[0].tools == ["read"] and (.[0].system | contains("MODEL_GUIDANCE"))' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
printf '[{"text":"stage setup"},{"text":"staged consumed"},{"text":"fallback default"}]' >"$tmp_root/script.json"
PRESETS_DEFAULT=yes PRESETS_DRIVER_STAGE=persona "$mare_bin" -C "$tmp_root/work" -p --no-session 'stage persona for next session' >"$tmp_root/stage_setup.txt"
: >"$PRESETS_CAPTURE"
PRESETS_DEFAULT=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'staged preset consumed on restart' >"$tmp_root/staged_consumed.txt"
jq -s -e 'length == 1 and (.[0].system | contains("PERSONA_PREFIX echo")) and (.[0].system | contains("PERSONA_SUFFIX")) and (.[0].system | contains("<environment>") | not) and (.[0].tools | index("write") | not)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_DEFAULT=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'subsequent run falls back to persisted default' >"$tmp_root/staged_fallback.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].effort == "high" and .[0].tools == ["read"] and (.[0].system | contains("MODEL_GUIDANCE"))' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
printf '[{"text":"stage recoverable"},{"text":"failed start"},{"text":"recovered start"},{"text":"fallback default"}]' >"$tmp_root/script.json"
PRESETS_DEFAULT=yes PRESETS_DRIVER_STAGE=recoverable "$mare_bin" -C "$tmp_root/work" -p --no-session 'stage recoverable preset' >"$tmp_root/stage_recoverable.txt"
: >"$PRESETS_CAPTURE"
PRESETS_DEFAULT=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'staged fails when model missing' >"$tmp_root/stage_fail.txt"
jq -s -e 'length == 1 and (.[0].system | contains("RECOVERED_GUIDANCE") | not) and (.[0].system | contains("MODEL_GUIDANCE") | not) and (.[0].tools | length > 1)' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_DEFAULT=yes PRESETS_HAS_RECOVERABLE=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'staged recovers and consumes once model available' >"$tmp_root/stage_recover.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].tools == ["read"] and (.[0].system | contains("RECOVERED_GUIDANCE"))' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
PRESETS_DEFAULT=yes "$mare_bin" -C "$tmp_root/work" -p --no-session 'after recovery staged is consumed and falls back to default' >"$tmp_root/stage_after_recover.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].tools == ["read"] and (.[0].system | contains("MODEL_GUIDANCE"))' "$PRESETS_CAPTURE" >/dev/null
: >"$PRESETS_CAPTURE"
printf '[{"text":"clear persisted default"},{"text":"cfg default"}]' >"$tmp_root/script.json"
PRESETS_DEFAULT=yes PRESETS_DRIVER_SET_DEFAULT=clear "$mare_bin" -C "$tmp_root/work" -p --no-session 'clear persisted default' >"$tmp_root/clear_default.txt"
: >"$PRESETS_CAPTURE"
PRESETS_CFG_DEFAULT=selected "$mare_bin" -C "$tmp_root/work" -p --no-session 'top-level cfg.default applies' >"$tmp_root/cfg_default.txt"
jq -s -e 'length == 1 and .[0].model == "presets-faux/selected" and .[0].effort == "high" and .[0].tools == ["read"] and (.[0].system | contains("MODEL_GUIDANCE"))' "$PRESETS_CAPTURE" >/dev/null
PRESETS_DEFAULT=yes python3 "$repo_root/tests/presets-tui.py" "$mare_bin" "$tmp_root/work"
printf 'presets file:// faux prompt/tools, saved model, fallback, actual read/denied write, later-hook constraint, default/staged and /new lifecycle passed\n'
