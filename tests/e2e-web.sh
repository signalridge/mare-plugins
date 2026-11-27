#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mare_bin="${MARE_BIN:-$repo_root/../mare/target/debug/mare}"
if [[ "$mare_bin" != */* ]]; then
	mare_bin="$(command -v "$mare_bin" || true)"
fi
if [[ -z "$mare_bin" || ! -x "$mare_bin" ]]; then
	printf 'mare-plugins: executable not found: %s (set MARE_BIN; core is not built automatically)\n' "${MARE_BIN:-$repo_root/../mare/target/debug/mare}" >&2
	exit 1
fi

export MARE_BIN="$mare_bin"
case "$(uname -s 2>/dev/null || true)" in
	MINGW*|MSYS*|CYGWIN*) export WEB_PTY="${WEB_PTY:-0}" ;;
	*) export WEB_PTY="${WEB_PTY:-1}" ;;
esac

python3 "$repo_root/tests/e2e-web.py"
python3 "$repo_root/tests/e2e-web-rpc.py"
