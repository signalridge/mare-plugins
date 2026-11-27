#!/usr/bin/env bash
set -uo pipefail

if [[ "${1:-}" == "--print-summary" ]]; then
	summary_file="${2:-${MARE_E2E_SKIP_SUMMARY:-}}"
	if [[ -n "$summary_file" && -s "$summary_file" ]]; then
		printf '\n=== Waived capability skips summary ===\n'
		cat "$summary_file"
	else
		printf '\n=== Waived capability skips summary: none ===\n'
	fi
	exit 0
fi

if [[ "$#" -eq 0 ]]; then
	printf 'usage: %s <command...>\n' "$0" >&2
	exit 2
fi

step_name=""
for arg in "$@"; do
	case "$arg" in
		*.sh|*.py)
			step_name="$(basename -- "$arg")"
			break
			;;
	esac
done
: "${step_name:=$(basename -- "$1")}"

rc=0
"$@" || rc=$?
if [[ $rc -ne 77 ]]; then
	exit "$rc"
fi

# Explicit allowlist of confirmed core capability gaps or host binary waivers.
# Any unlisted target returning rc=77 fails hard instead of silently passing.
is_windows=0
case "$(uname -s 2>/dev/null || true)" in
	MINGW*|MSYS*|CYGWIN*) is_windows=1 ;;
esac
reason=""
tracking=""
case "$step_name" in
	e2e-mermaid.sh)
		reason="missing optional host external binaries (mmdc/node)"
		tracking="host-env:optional-bins"
		;;
	e2e-toolbelt.sh)
		reason="missing optional host external binaries (rg/fd/ast-grep/rga)"
		tracking="host-env:optional-bins"
		;;
	e2e-todo.sh|e2e-ask-user-question.sh|e2e-presets.sh|e2e-btw.sh|e2e-session-title.sh|e2e-time-context.sh|e2e-hooks-events.sh|e2e-hooks-input.sh|e2e-hooks-parity.sh|e2e-session-search.sh)
		if [[ "$is_windows" -eq 1 ]]; then
			reason="POSIX PTY driver"
			tracking="host-env:posix-pty"
		else
			printf 'ERROR: %s returned rc=77 (unlisted capability skip is forbidden)\n' "$step_name" >&2
			exit 1
		fi
		;;
	*)
		printf 'ERROR: %s returned rc=77 (unlisted capability skip is forbidden)\n' "$step_name" >&2
		exit 1
		;;
esac

line="[WAIVED_SKIP] $step_name: $reason [$tracking]"
printf '%s\n' "$line" >&2
if [[ -n "${MARE_E2E_SKIP_SUMMARY:-}" ]]; then
	printf '%s\n' "$line" >> "$MARE_E2E_SKIP_SUMMARY"
fi
exit 0
