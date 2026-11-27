#!/usr/bin/env bash
set -euo pipefail
# the fixture's MARE_HOME/state dirs must not be group-writable: core refuses a spill root with a
# group/world-writable ancestor (mare-binding spill/local.rs trusted_directory); with umask 002 the
# directories this test creates would be 0775 (core question routed separately)
umask 022
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then mare_bin="$(command -v "$mare_bin")"; fi
[[ -x "$mare_bin" ]] || {
	printf 'Set MARE_BIN to an existing mare executable (tried %s)\n' "$mare_bin" >&2
	exit 1
}
export MARE_BIN="$mare_bin"
python3 "$repo_root/tests/e2e-spill.py"
