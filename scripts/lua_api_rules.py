#!/usr/bin/env python3
"""Public Lua API, underscore-internal, and boundary audit rules for mare-plugins.

Ported from mare's `scripts/lua_api_rules.py`, `scripts/lua_api_runner.py`, and
`scripts/lua_api_legacy.py` with zero exceptions/baselines for plugin code:
- Forbids `mare._*` and `ui._*` private API accesses.
- Forbids Cordis underscore internals (`_internal`, `_error`, `_hooks`, `_resolve`,
  `_disposables`, and any `fiber._*` including `_store`).
- Forbids reading `ctx.root`, dynamic loader/global bypasses (`package`, `_ENV`,
  `_G[...]`, `loadstring`, undeclared/dynamic `require`), bare cordis event
  dispatches on public events, and removed legacy `ctx` APIs.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CTX_RECEIVER = re.compile(r"(?:ctx|caller|scope|owner|sub|self\.ctx|D\.ctx)")

PUBLIC_CORE_MODULES = {
    "cordis",
    "mare_lib",
    "mare_lib.baseline_page",
    "mare_lib.schema_sanitize",
    "mare_lib.table_revision",
}

CORDIS_UNDERSCORE_FIELDS = {
    "_internal",
    "_error",
    "_hooks",
    "_resolve",
    "_disposables",
}

_FIBER_RECEIVER_RE = re.compile(r"(?:^|[._])fiber$", re.IGNORECASE)

BARE_DISPATCH_MODES = {
    "emit",
    "emit_checked",
    "serial",
    "parallel",
    "bail",
    "waterfall",
    "waterfall_checked",
}

LEGACY_CTX_NAMES = [
    "on_dispose",
    "with_service",
    "emit_local",
    "emit_checked",
    "emit_checked_local",
    "bail_local",
    "waterfall_local",
    "waterfall_checked",
    "waterfall_checked_local",
    "policy",
    "policy_with",
    "rewrite",
    "on_local",
    "declare_local",
    "has_listeners",
    "has_local_listeners",
    "policy_epoch",
    "service",
    "provides",
    "permitted",
    "validate",
    "log",
    "reload",
    "reload_barrier",
    "plugins",
    "problems",
    "is_builtin",
    "profile",
    "profile_mark",
    "slow_callbacks",
    "callback_timings",
    "call_service",
]

LEGACY_RECEIVER = r"(?:\bctx|\bcaller|\bscope|\bowner|\bc|\bsub|self\.ctx|D\.ctx)"

LEGACY_PATTERNS = [
    (
        re.compile(
            LEGACY_RECEIVER
            + r"\s*:\s*("
            + "|".join(sorted(LEGACY_CTX_NAMES, key=len, reverse=True))
            + r")\s*\("
        ),
        "the old Ctx's `{0}` (the cordis ctx has none)",
    ),
    (
        re.compile(LEGACY_RECEIVER + r"\s*:\s*inject\s*\(\s*[\"']"),
        'the old single-name `inject("x")`',
    ),
    (re.compile(r"\bcordis\s*=\s*true\b"), "the removed `cordis = true` switch"),
]

ON_PRIORITY_FIELD_RULE = {
    "any": [
        {"pattern": {"context": "{ priority = $VALUE }", "selector": "field"}},
        {"pattern": {"context": '{ ["priority"] = $VALUE }', "selector": "field"}},
        {"pattern": {"context": "{ ['priority'] = $VALUE }", "selector": "field"}},
    ]
}

ON_PRIORITY_RULE = {
    "id": "legacy-on-priority",
    "language": "Lua",
    "rule": {
        "any": [
            {"pattern": "$CTX:on($EVENT, $HANDLER, $OPTS)"},
            {"pattern": "$CTX:on($EVENT, $HANDLER, $OPTS, $$$EXTRA)"},
        ]
    },
    "constraints": {
        "OPTS": {
            "any": [
                {"kind": "table_constructor", "has": ON_PRIORITY_FIELD_RULE},
                {
                    "kind": "parenthesized_expression",
                    "has": {
                        "kind": "table_constructor",
                        "has": ON_PRIORITY_FIELD_RULE,
                        "stopBy": {"not": {"kind": "parenthesized_expression"}},
                    },
                },
            ]
        }
    },
}


def ast_grep_matches(returncode: int, stdout: str, stderr: str, what: str) -> list[dict]:
    """Parse ast-grep --json=compact output; scanner errors never read as zero violations."""
    if returncode not in (0, 1):
        raise RuntimeError(f"{what} failed (exit {returncode}): {stderr.strip()}")
    if "ERROR:" in stderr:
        raise RuntimeError(f"{what} reported an error: {stderr.strip()}")
    if not stdout.strip():
        raise RuntimeError(f"{what} produced no output (expected a JSON array)")
    try:
        matches = json.loads(stdout)
    except json.JSONDecodeError as err:
        raise RuntimeError(f"{what} produced invalid JSON: {err}") from err
    if not isinstance(matches, list):
        raise RuntimeError(
            f"{what} produced {type(matches).__name__}, not an array of matches"
        )
    for match in matches:
        offset = (
            match.get("range", {}).get("byteOffset") if isinstance(match, dict) else None
        )
        if not (
            isinstance(match.get("file") if isinstance(match, dict) else None, str)
            and isinstance(offset, dict)
            and isinstance(offset.get("start"), int)
            and isinstance(offset.get("end"), int)
        ):
            raise RuntimeError(
                f"{what} produced an entry that is not a match: {match!r:.200}"
            )
    return matches


def _run_ast_grep(
    cwd: Path,
    files: list[str],
    pattern: str,
    what: str,
    selector: str | None = None,
) -> list[dict]:
    if not files:
        return []
    command = [
        "ast-grep",
        "run",
        "--lang",
        "lua",
        "--pattern",
        pattern,
        "--json=compact",
    ]
    if selector:
        command += ["--selector", selector]
    result = subprocess.run(
        [*command, *files],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        encoding="utf-8",
    )
    return ast_grep_matches(result.returncode, result.stdout, result.stderr, what)


def _scan_ast_grep(cwd: Path, files: list[str], rules_yaml: str, what: str) -> list[dict]:
    if not files:
        return []
    result = subprocess.run(
        ["ast-grep", "scan", "--inline-rules", rules_yaml, "--json=compact", *files],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        encoding="utf-8",
    )
    return ast_grep_matches(result.returncode, result.stdout, result.stderr, what)


def _unwrap_parens(expr: str) -> str:
    expr = expr.strip()
    while expr.startswith("(") and expr.endswith(")"):
        depth = 0
        wrapped = True
        for index, ch in enumerate(expr):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and index < len(expr) - 1:
                    wrapped = False
                    break
        if not wrapped or depth != 0:
            break
        expr = expr[1:-1].strip()
    return expr


def string_literal(text: str) -> str | None:
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    long = re.fullmatch(r"\[(=*)\[(.*)\]\1\]", text, re.DOTALL)
    return long[2] if long else None


def decode_lua_string(text: str) -> str | None:
    value = string_literal(text)
    if value is None or text.startswith("["):
        return value

    def unescape(match: re.Match[str]) -> str:
        escape = match[1]
        if escape.isdecimal():
            return chr(int(escape))
        if escape.startswith("x"):
            return chr(int(escape[1:], 16))
        if escape.startswith("u{"):
            return chr(int(escape[2:-1], 16))
        if escape.startswith("z"):
            return ""
        return {
            "a": "\a",
            "b": "\b",
            "f": "\f",
            "n": "\n",
            "r": "\r",
            "t": "\t",
            "v": "\v",
        }.get(escape, escape)

    return re.sub(
        r"\\(\d{1,3}|x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|z\s*|\r?\n|.)",
        unescape,
        value,
    )


def _is_cordis_fiber_receiver(table: str) -> bool:
    tail = table.strip().rsplit(".", 1)[-1].rsplit(":", 1)[-1]
    return bool(_FIBER_RECEIVER_RE.search(table.strip())) or tail.lower().endswith("fiber")


def source_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for rel_dir in ("plugins", "themes"):
        base = root / rel_dir
        if base.is_dir():
            files.extend(sorted(base.rglob("*.lua")))
    return files


def load_public_modules(types_dir: Path | None) -> set[str]:
    modules = set(PUBLIC_CORE_MODULES)
    if types_dir is not None and types_dir.is_dir():
        for path in types_dir.rglob("*.lua"):
            for match in re.finditer(
                r"(?m)^---@meta\s+([\w.-]+)", path.read_text(encoding="utf-8")
            ):
                if match[1] != "_":
                    modules.add(match[1])
    return modules


def load_public_events(types_dir: Path | None) -> set[str] | None:
    if types_dir is None:
        return None
    events_gen = types_dir / "mare" / "events.gen.lua"
    if not events_gen.is_file():
        return None
    text = events_gen.read_text(encoding="utf-8")
    return set(re.findall(r"^---\s+`([^`]+)`\s+\(`mode\s*=", text, re.M))


def private_and_cordis_underscore_violations(files: list[Path], root: Path) -> list[str]:
    """Forbid mare._*, ui._*, Cordis underscore internals, and any fiber._*."""
    if not files:
        return []
    rel_files = [path.relative_to(root).as_posix() for path in files]
    errors: list[tuple[tuple[str, int, int], str]] = []
    seen: set[tuple[str, int, int, str]] = set()
    for pattern, selector in (
        ("$TABLE.$FIELD", "dot_index_expression"),
        ("$TABLE:$FIELD()", "method_index_expression"),
        ("$TABLE[$KEY]", "bracket_index_expression"),
        ("rawget($TABLE, $KEY)", None),
        ("rawset($TABLE, $KEY, $VALUE)", None),
    ):
        matches = _run_ast_grep(
            root, rel_files, pattern, "underscore internal scanner", selector=selector
        )
        for match in matches:
            variables = match["metaVariables"]["single"]
            table = _unwrap_parens(variables.get("TABLE", {}).get("text", ""))
            if not table:
                continue
            if "KEY" in variables:
                key = decode_lua_string(variables["KEY"]["text"])
            else:
                key = variables.get("FIELD", {}).get("text", "")
            if not key or not key.startswith("_"):
                continue

            rel_path = Path(match["file"]).as_posix()
            start = match["range"]["start"]
            access = f"{table}.{key}"
            dedup_key = (rel_path, start["line"], start["column"], access)
            if dedup_key in seen:
                continue

            if table in {"mare", "ui"}:
                seen.add(dedup_key)
                errors.append(
                    (
                        (rel_path, start["line"], start["column"]),
                        (
                            f"{rel_path}:{start['line'] + 1}:{start['column'] + 1}: "
                            f"private-api: forbidden private API access `{access}`"
                        ),
                    )
                )
            elif key in CORDIS_UNDERSCORE_FIELDS or _is_cordis_fiber_receiver(table):
                seen.add(dedup_key)
                errors.append(
                    (
                        (rel_path, start["line"], start["column"]),
                        (
                            f"{rel_path}:{start['line'] + 1}:{start['column'] + 1}: "
                            f"cordis-underscore: forbidden Cordis internal access `{access}`"
                        ),
                    )
                )
    return [message for _, message in sorted(errors)]


def _plugin_dir_for(rel_path: str, root: Path) -> Path | None:
    parts = Path(rel_path).parts
    if len(parts) >= 2 and parts[0] == "plugins":
        return root / parts[0] / parts[1]
    return None


def boundary_and_import_violations(
    files: list[Path],
    root: Path,
    public_modules: set[str],
) -> list[str]:
    """Check ctx.root, require boundaries, package/_ENV/_G[...]/loadstring/load."""
    if not files:
        return []
    rel_files = [path.relative_to(root).as_posix() for path in files]
    errors: list[tuple[tuple[str, int, int], str]] = []
    reported: set[tuple[str, int, int]] = set()

    def add_error(rel: str, start: dict, code: str, message: str) -> None:
        pos = (rel, start["line"], start["column"])
        if pos in reported:
            return
        reported.add(pos)
        errors.append(
            (pos, f"{rel}:{start['line'] + 1}:{start['column'] + 1}: {code}: {message}")
        )

    blocks_by_file: dict[str, list[tuple[int, int]]] = {}
    for match in _scan_ast_grep(
        root, rel_files, "id: block\nlanguage: lua\nrule:\n  kind: block", "Lua block scanner"
    ):
        offset = match["range"]["byteOffset"]
        blocks_by_file.setdefault(Path(match["file"]).as_posix(), []).append(
            (offset["start"], offset["end"])
        )

    local_load_scopes: dict[str, list[tuple[int, int]]] = {}
    for pattern in (
        "local function load($$$ARGS) $$$BODY end",
        "local load = function($$$ARGS) $$$BODY end",
    ):
        for match in _run_ast_grep(root, rel_files, pattern, "local load scanner"):
            rel = Path(match["file"]).as_posix()
            offset = match["range"]["byteOffset"]
            decl_start, decl_end = offset["start"], offset["end"]
            enclosing = [
                (b_start, b_end)
                for b_start, b_end in blocks_by_file.get(rel, ())
                if b_start <= decl_start and decl_end <= b_end
            ]
            scope_end = (
                min(enclosing, key=lambda span: span[1] - span[0])[1]
                if enclosing
                else (root / rel).stat().st_size
            )
            local_load_scopes.setdefault(rel, []).append((decl_start, scope_end))

    # Workflow's sandbox VM pre-validates user workflow scripts with `load(src, "=workflow", "t")`
    # without executing the returned chunk.
    workflow_syntax_loads: set[tuple[str, int]] = set()
    for match in _run_ast_grep(
        root, rel_files, 'load($SRC, "=workflow", "t")', "workflow syntax load scanner"
    ):
        rel = Path(match["file"]).as_posix()
        if rel.startswith("plugins/workflow/"):
            workflow_syntax_loads.add((rel, match["range"]["byteOffset"]["start"]))

    # 1. Dynamic bracket access on _G, _ENV, or package.
    for match in _run_ast_grep(
        root, rel_files, "$TABLE[$KEY]", "bracket index scanner", selector="bracket_index_expression"
    ):
        table = _unwrap_parens(match["metaVariables"]["single"].get("TABLE", {}).get("text", ""))
        rel = Path(match["file"]).as_posix()
        if table in {"_ENV", "_G"}:
            add_error(
                rel,
                match["range"]["start"],
                "public-module",
                "dynamic global/loader access via _G/_ENV is forbidden",
            )
        elif table == "package":
            add_error(
                rel,
                match["range"]["start"],
                "public-module",
                "dynamic loader access via package is forbidden",
            )

    # 2. Forbid ctx.root reads.
    for pattern, selector in (
        ("$TABLE.root", "dot_index_expression"),
        ("$TABLE[$KEY]", "bracket_index_expression"),
    ):
        for match in _run_ast_grep(
            root, rel_files, pattern, "ctx.root scanner", selector=selector
        ):
            variables = match["metaVariables"]["single"]
            table = _unwrap_parens(variables.get("TABLE", {}).get("text", ""))
            if selector == "bracket_index_expression" and variables.get("KEY", {}).get(
                "text"
            ) not in {'"root"', "'root'"}:
                continue
            if CTX_RECEIVER.fullmatch(table):
                add_error(
                    Path(match["file"]).as_posix(),
                    match["range"]["start"],
                    "public-api",
                    "plugin code must not read the root context (ctx.root); observe every scope with { global = true }",
                )

    # 3. Direct require calls and forbidden boundary identifiers.
    calls = _run_ast_grep(root, rel_files, "require $ARG", "require scanner")
    direct_requires = {
        (Path(match["file"]).as_posix(), match["range"]["byteOffset"]["start"])
        for match in calls
    }

    for name in ("require", "load", "loadstring", "_ENV", "package"):
        fields: set[tuple[str, int]] = set()
        for pattern, selector, at_end in (
            (f"$TABLE.{name}", "dot_index_expression", True),
            (f"$TABLE:{name}()", "method_index_expression", True),
            (f"{{{name} = $VALUE}}", "field", False),
        ):
            for match in _run_ast_grep(
                root, rel_files, pattern, f"{name} field scanner", selector=selector
            ):
                table = match["metaVariables"]["single"].get("TABLE", {}).get("text", "")
                if _unwrap_parens(table) in {"_ENV", "_G", "package"}:
                    continue
                offset = match["range"]["byteOffset"]
                fields.add(
                    (
                        Path(match["file"]).as_posix(),
                        offset["end"] - len(name) if at_end else offset["start"],
                    )
                )
        for match in _run_ast_grep(
            root, rel_files, name, f"{name} identifier scanner", selector="identifier"
        ):
            rel = Path(match["file"]).as_posix()
            byte_start = match["range"]["byteOffset"]["start"]
            if (rel, byte_start) in fields:
                continue
            if name == "require":
                if (rel, byte_start) in direct_requires:
                    continue
                add_error(
                    rel,
                    match["range"]["start"],
                    "public-module",
                    "require must be a direct checked call; storing/passing the loader cannot be resolved",
                )
            elif name in {"load", "loadstring"}:
                if name == "load" and (
                    (rel, byte_start) in workflow_syntax_loads
                    or any(
                        s <= byte_start <= e for s, e in local_load_scopes.get(rel, ())
                    )
                ):
                    continue
                add_error(
                    rel,
                    match["range"]["start"],
                    "public-module",
                    "dynamic code loading via load/loadstring is forbidden",
                )
            elif name == "_ENV":
                add_error(
                    rel,
                    match["range"]["start"],
                    "public-module",
                    "dynamic global/loader access via _ENV is forbidden",
                )
            elif name == "package":
                add_error(
                    rel,
                    match["range"]["start"],
                    "public-module",
                    "dynamic loader access via package is forbidden",
                )

    for match in calls:
        rel = Path(match["file"]).as_posix()
        argument = _unwrap_parens(match["metaVariables"]["single"]["ARG"]["text"])
        literal = re.fullmatch(r"(['\"])([\w.-]+)\1", argument)
        long_literal = re.fullmatch(r"\[(=*)\[([\w.-]+)\]\1\]", argument)
        module = literal[2] if literal else long_literal[2] if long_literal else None
        owned_exists = False
        if module is not None:
            plugin_dir = _plugin_dir_for(rel, root)
            if plugin_dir is not None:
                mod_path = plugin_dir / "lua" / module.replace(".", "/")
                owned_exists = (
                    mod_path.with_suffix(".lua").is_file()
                    or (mod_path / "init.lua").is_file()
                )
        if module in public_modules or owned_exists:
            continue
        add_error(
            rel,
            match["range"]["start"],
            "public-module",
            f"undeclared import {module!r}" if module else "unresolved dynamic import",
        )

    return [message for _, message in sorted(errors)]


def public_event_violations(
    files: list[Path],
    root: Path,
    public_events: set[str] | None,
) -> list[str]:
    """Forbid bare cordis dispatch on public events (must emit through ctx.bus)."""
    if not files:
        return []
    rel_files = [path.relative_to(root).as_posix() for path in files]
    errors: list[tuple[tuple[str, int, int], str]] = []
    seen: set[tuple[str, int, int]] = set()
    for pattern in ("$R:$M($E, $$$A)", "$R:$M($E)"):
        for match in _run_ast_grep(root, rel_files, pattern, "public-event scanner"):
            single = match["metaVariables"]["single"]
            receiver, mode = single["R"]["text"], single["M"]["text"]
            event = string_literal(single["E"]["text"])
            start = match["range"]["start"]
            rel = Path(match["file"]).as_posix()
            key = (rel, start["line"], start["column"])
            if key in seen or mode not in BARE_DISPATCH_MODES or event is None:
                continue
            seen.add(key)
            is_bus = receiver.split(".")[-1] == "bus" or bool(
                re.search(r''':get\s*\(\s*(["'])bus\1\s*\)\s*$''', receiver)
            )
            if is_bus:
                continue
            if public_events is not None:
                is_public = event in public_events
            else:
                is_public = bool(
                    CTX_RECEIVER.fullmatch(_unwrap_parens(receiver))
                    and "/" in event
                    and not event.startswith("internal/")
                )
            if is_public:
                errors.append(
                    (
                        key,
                        (
                            f"{rel}:{start['line'] + 1}:{start['column'] + 1}: public-event: "
                            f"`{event}` is a public event: emit it through ctx.bus:{mode}, "
                            f"not a bare cordis dispatch"
                        ),
                    )
                )
    return [message for _, message in sorted(errors)]


def legacy_api_violations(files: list[Path], root: Path) -> list[str]:
    """Forbid removed pre-Cordis ctx methods, single-name inject, cordis=true, and :on priority."""
    errors: list[str] = []
    for path in files:
        source = path.read_text(encoding="utf-8")
        found: list[tuple[int, int, str]] = []
        for number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith("--"):
                continue
            for pattern, what in LEGACY_PATTERNS:
                for match in pattern.finditer(line):
                    found.append((number, match.start() + 1, what.format(*match.groups())))
        if re.search(r":\s*on\s*\(", source) and re.search(r"\bpriority\b", source):
            result = subprocess.run(
                [
                    "ast-grep",
                    "scan",
                    "--inline-rules",
                    json.dumps(ON_PRIORITY_RULE),
                    "--stdin",
                    "--json=compact",
                ],
                input=source,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
                encoding="utf-8",
            )
            for match in ast_grep_matches(
                result.returncode, result.stdout, result.stderr, "Lua :on priority parser"
            ):
                found.append(
                    (
                        match["range"]["start"]["line"] + 1,
                        match["range"]["start"]["column"] + 1,
                        "a numeric `priority` (listeners run in registration order)",
                    )
                )
        rel = path.relative_to(root).as_posix()
        for line_no, column, message in sorted(found):
            errors.append(f"{rel}:{line_no}:{column}: legacy-api: {message}")
    return errors


def check_repo(root: Path, types_dir: Path | None = None) -> list[str]:
    files = source_files(root)
    public_modules = load_public_modules(types_dir)
    public_events = load_public_events(types_dir)
    errors: list[str] = []
    errors.extend(private_and_cordis_underscore_violations(files, root))
    errors.extend(boundary_and_import_violations(files, root, public_modules))
    errors.extend(public_event_violations(files, root, public_events))
    errors.extend(legacy_api_violations(files, root))
    return sorted(errors)


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="mare-plugins-lua-api-selftest-") as tmp:
        root = Path(tmp)
        pdir = root / "plugins" / "probe"
        (pdir / "lua" / "probe").mkdir(parents=True)
        (pdir / "lua" / "probe" / "helper.lua").write_text("return {}\n", encoding="utf-8")
        (pdir / "init.lua").write_text(
            "\n".join(
                [
                    'local helper = require("probe.helper")',  # 1: ok
                    'local lib = require("mare_lib")',  # 2: ok
                    "local a = mare._private",  # 3: private-api
                    "local b = ui._internal_widget",  # 4: private-api
                    "local c = fiber._error",  # 5: cordis-underscore
                    "local d = loaderFiber._store",  # 6: cordis-underscore
                    "local e = events._hooks",  # 7: cordis-underscore
                    "local f = ctx.root",  # 8: ctx.root
                    'local g = require("foreign.mod")',  # 9: undeclared import
                    "local h = package.loaded",  # 10: package
                    'ctx:emit("session/started", {})',  # 11: bare public-event
                    'ctx.bus:emit("session/started", {})',  # 12: ok
                    "ctx:on_dispose(function() end)",  # 13: legacy-api
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        violations = check_repo(root)
        lines = sorted({int(err.split(":")[1]) for err in violations})
        expected = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13]
        assert lines == expected, f"expected violation lines {expected}, got {lines} ({violations})"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help="repository root to scan (defaults to this repository)",
    )
    parser.add_argument(
        "--types-dir",
        type=Path,
        default=None,
        help="optional mare types/ directory for public module and event discovery",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run built-in self-test against synthetic Lua fixtures",
    )
    args = parser.parse_args()
    if not shutil.which("ast-grep"):
        parser.error("ast-grep with Lua support is required")
    if args.self_test:
        self_test()
        print("lua_api_rules: self-test passed")
        return 0
    root = args.root.resolve()
    files = source_files(root)
    violations = check_repo(root, types_dir=args.types_dir)
    for err in violations:
        print(err)
    print(f"lua_api_rules: {len(violations)} violation(s) across {len(files)} Lua file(s)")
    return int(bool(violations))


if __name__ == "__main__":
    raise SystemExit(main())
