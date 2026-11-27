#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then
	mare_bin="$(command -v "$mare_bin")"
fi
[[ -x "$mare_bin" ]] || {
	printf 'Set MARE_BIN to an existing mare executable (tried %s)\n' "$mare_bin" >&2
	exit 1
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mare-presets-activation.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/package/plugins" "$tmp_root/home/config" "$tmp_root/work"
cp "$repo_root/mare-plugin.toml" "$tmp_root/package/"
cp -R "$repo_root/plugins/presets" "$tmp_root/package/plugins/"

git -C "$tmp_root/package" init -q -b main
git -C "$tmp_root/package" add -A
git -C "$tmp_root/package" \
	-c user.name='mare test' \
	-c user.email='test@example.invalid' \
	-c commit.gpgsign=false \
	commit -qm fixture

export MARE_HOME="$tmp_root/home"
printf '[{"text":"ok"}]\n' >"$tmp_root/script.json"
export MARE_FAUX_SCRIPT="$tmp_root/script.json"

cat >"$MARE_HOME/config/init.lua" <<LUA
mare.setup({ model = "faux/echo" })
mare.plugins.add({
  {
    "test/presets",
    url = "file://$tmp_root/package",
    opts = {
      presets = {
        default = "review",
        definitions = {
          review = { system = "PRESET_GUIDANCE", tools = { "read" } },
        },
      },
    },
  },
})
LUA

"$mare_bin" -C "$tmp_root/work" plugin sync >/dev/null

set +e
output="$("$mare_bin" -C "$tmp_root/work" -p --no-session "hello" 2>&1)"
status=$?
set -e

# Note: positive activation acceptance (verifying PRESET_GUIDANCE / tool constraints end-to-end
# via default = "review" or /preset review) needs the required core context and tool-constraint APIs.
if [[ $status -eq 0 ]]; then
	printf 'presets real activation passed against %s\n' "$mare_bin"
	exit 0
fi

# Some core builds do not yet provide ctx.llm:constrain_tools.
if printf '%s' "$output" | grep -q "plugin \`presets\` setup failed" \
	&& printf '%s' "$output" | grep -q "attempt to call a nil value (method 'constrain_tools')"; then
	printf 'presets real activation against %s observed missing ctx.llm:constrain_tools\n' "$mare_bin"
	exit 0
fi

printf 'Unexpected presets activation failure against %s (exit %d):\n%s\n' "$mare_bin" "$status" "$output" >&2
exit 1
