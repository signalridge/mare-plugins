#!/usr/bin/env python3
"""In-repo Claude Code PreToolUse Bash validator fixture for hooks_spec.lua."""

from __future__ import annotations

import json
import re
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"invalid JSON hook input: {exc}", file=sys.stderr)
        return 1

    if payload.get("tool_name") != "Bash":
        return 0

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0

    command = tool_input.get("command")
    if not isinstance(command, str) or not command:
        return 0

    if re.search(r"^grep\b(?!.*\|)", command):
        print("Use 'rg' instead of 'grep' for codebase search.", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
