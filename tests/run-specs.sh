#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mare_bin="${MARE_BIN:-mare}"
if ! command -v "$mare_bin" >/dev/null 2>&1 && [[ ! -x "$mare_bin" ]]; then
	printf 'mare executable not found: %s (set MARE_BIN or ensure mare is in PATH)\n' "$mare_bin" >&2
	exit 2
fi

# Specs write real state (presets: state.json and its lock; schedule: durable stores). A fresh
# MARE_HOME per run keeps them off the user's ~/.local/state and keeps concurrent runs from
# sharing one store (they failed each other's schedule_*/presets_* specs).
spec_home="$(mktemp -d "${TMPDIR:-/tmp}/mare-plugins-specs.XXXXXX")"
trap 'rm -rf "$spec_home"' EXIT
MARE_HOME="$spec_home" "$mare_bin" test tests/specs "$@"
