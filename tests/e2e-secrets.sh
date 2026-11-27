#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then
	mare_bin="$(command -v "$mare_bin" || true)"
fi
[[ -x "$mare_bin" ]] || {
	printf 'Set MARE_BIN to an existing mare executable\n' >&2
	exit 1
}

publication_bin="${PUBLICATION_BIN:-$mare_bin}"
if [[ "$publication_bin" != */* ]]; then
	publication_bin="$(command -v "$publication_bin" || true)"
fi
[[ -x "$publication_bin" ]] || {
	printf 'Set PUBLICATION_BIN to an existing mare executable\n' >&2
	exit 1
}

if [[ -z "${TMPDIR:-}" ]]; then
	if [[ -d "$HOME/tht" ]]; then
		export TMPDIR="$HOME/tht"
	else
		export TMPDIR="/tmp"
	fi
fi

export MARE_BIN="$mare_bin"
export PUBLICATION_BIN="$publication_bin"

python3 "$repo_root/tests/secrets/e2e.py"
python3 "$repo_root/tests/secrets/storage_e2e.py"
python3 "$repo_root/tests/secrets/tui_e2e.py"
python3 "$repo_root/tests/secrets/publication_e2e.py"
