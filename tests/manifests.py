"""Validate the repository and plugin manifests."""

import json
import pathlib
import re
import tomllib

MANIFEST = "mare-plugin.toml"
LEGACY_MANIFEST = "mare-" + "pkg.toml"
RELEASE_MANIFEST = ".release-please-manifest.json"
CATEGORIES = {"agent", "coding", "lang", "tools", "integration", "ui"}
PLATFORMS = {"linux", "macos", "windows"}
PROVIDES = {
    "tools",
    "commands",
    "hooks",
    "skills",
    "prompts",
    "themes",
    "services",
    "flags",
    "mcp",
}

# Matches the syntax consumed by semver::VersionReq in mare-plugin-manager's health check.
COMPARATOR = re.compile(
    r" *(?:>=|<=|>|<|=|\^|~)? *([0-9]+)"
    r"(?:\.([0-9]+|[xX*])(?:\.([0-9]+|[xX*]))?)?"
    r"(?:-([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*))?"
    r"(?:\+([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*))? *"
)


def valid_version_requirement(text: str) -> bool:
    if text.strip(" ") in {"*", "x", "X"}:
        return True
    comparators = text.split(",")
    if len(comparators) > 32:
        return False
    for comparator in comparators:
        match = COMPARATOR.fullmatch(comparator)
        if not match:
            return False
        major, minor, patch, prerelease, build = match.groups()
        for number in (major, minor, patch):
            if (
                number is not None
                and number.isdigit()
                and (
                    (len(number) > 1 and number.startswith("0"))
                    or int(number) > 2**64 - 1
                )
            ):
                return False
        if (
            minor in {"*", "x", "X"}
            and patch is not None
            and patch not in {"*", "x", "X"}
        ):
            return False
        if (prerelease or build) and (patch is None or patch in {"*", "x", "X"}):
            return False
        if prerelease and any(
            part.isdigit() and len(part) > 1 and part.startswith("0")
            for part in prerelease.split(".")
        ):
            return False
    return True


def string_list(value: object, *, nonempty: bool = False) -> bool:
    return (
        isinstance(value, list)
        and (not nonempty or bool(value))
        and all(isinstance(item, str) and item.strip() for item in value)
    )


def reject_legacy(data: object, path: pathlib.Path) -> None:
    if isinstance(data, dict):
        for key, value in data.items():
            if key == "packages":
                raise AssertionError(f"{path}: legacy packages section")
            if key in {"extras", "extensions"}:
                raise AssertionError(f"{path}: legacy {key} field")
            reject_legacy(value, path)
    elif isinstance(data, list):
        for item in data:
            reject_legacy(item, path)


def read_release_version(repo_root: pathlib.Path) -> str:
    path = repo_root / RELEASE_MANIFEST
    assert path.is_file(), f"{path}: missing {RELEASE_MANIFEST}"
    data = json.loads(path.read_text(encoding="utf-8"))
    version = data.get(".") if isinstance(data, dict) else None
    assert isinstance(version, str) and version.strip(), (
        f"{path}: missing root version in {RELEASE_MANIFEST}"
    )
    return version


def check_manifest(
    path: pathlib.Path,
    *,
    plugin: bool = False,
    expected_version: str | None = None,
) -> dict:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    assert isinstance(data.get("name"), str) and data["name"].strip(), (
        f"{path}: missing root `name`"
    )
    assert isinstance(data.get("requires"), str) and data["requires"].strip(), (
        f"{path}: missing root `requires`"
    )
    assert valid_version_requirement(data["requires"]), (
        f"{path}: invalid semver requirement"
    )
    reject_legacy(data, path)
    for section in ("recommended", "deps", "provides"):
        sub = data.get(section)
        if isinstance(sub, dict):
            assert "requires" not in sub, (
                f"{path}: `requires` must be at root, not inside [{section}]"
            )
    if "deps" in data:
        deps = data["deps"]
        assert isinstance(deps, dict), f"{path}: invalid deps table"
        for key in ("required", "optional"):
            if key in deps:
                assert string_list(deps[key]), f"{path}: invalid deps.{key}"
    if plugin:
        assert (
            isinstance(data.get("description"), str) and data["description"].strip()
        ), f"{path}: missing description"
        category = data.get("category")
        assert isinstance(category, str) and category in CATEGORIES, (
            f"{path}: invalid category"
        )
    if "platforms" in data:
        platforms = data["platforms"]
        assert string_list(platforms, nonempty=True) and set(platforms) <= PLATFORMS, (
            f"{path}: invalid platforms"
        )
    if "keywords" in data:
        keywords = data["keywords"]
        assert string_list(keywords) and 2 <= len(keywords) <= 5, (
            f"{path}: invalid keywords"
        )
    if "license" in data:
        assert isinstance(data["license"], str) and data["license"].strip(), (
            f"{path}: invalid license"
        )
    if "provides" in data:
        provides = data["provides"]
        assert isinstance(provides, dict) and provides, (
            f"{path}: invalid provides table"
        )
        for key, value in provides.items():
            assert key in PROVIDES and string_list(value, nonempty=True), (
                f"{path}: invalid provides.{key}"
            )

    version = data.get("version")
    assert isinstance(version, str) and version.strip(), (
        f"{path}: missing root `version`"
    )
    if expected_version is not None:
        assert version == expected_version, (
            f"{path}: version {version!r} does not match {RELEASE_MANIFEST} ({expected_version!r})"
        )
    if "recommended" in data:
        recommended = data["recommended"]
        assert isinstance(recommended, dict), f"{path}: invalid recommended table"
        assert "lua" not in recommended, f"{path}: recommended.lua is not supported"
        unknown_rec = set(recommended.keys()) - {"root", "cmd"}
        assert not unknown_rec, (
            f"{path}: unsupported recommended fields {sorted(unknown_rec)}"
        )
        for key in ("root", "cmd"):
            if key in recommended:
                assert string_list(recommended[key]), f"{path}: invalid recommended.{key}"
    if "web" in data:
        web = data["web"]
        assert isinstance(web, dict), f"{path}: invalid web table"
        unknown_web = set(web.keys()) - {"dir", "prefix", "index", "fallback"}
        assert not unknown_web, (
            f"{path}: unsupported web fields {sorted(unknown_web)}"
        )
        assert "dir" in web, f"{path}: missing web.dir"
        value = web["dir"]
        assert isinstance(value, str) and value.strip(), (
            f"{path}: invalid web.dir"
        )
        candidate = (path.parent / value).resolve()
        assert candidate.is_relative_to(path.parent.resolve()) and candidate.is_dir(), (
            f"{path}: missing or external web.dir: {value}"
        )
        for key in ("prefix", "index", "fallback"):
            if key in web:
                assert isinstance(web[key], str) and web[key].strip(), (
                    f"{path}: invalid web.{key}"
                )
    return data


def main() -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    legacy_manifests = [
        path
        for path in repo_root.rglob(LEGACY_MANIFEST)
        if ".git" not in path.relative_to(repo_root).parts
    ]
    assert not legacy_manifests, f"legacy manifest is not permitted: {legacy_manifests}"

    expected_version = read_release_version(repo_root)
    root = check_manifest(repo_root / MANIFEST, expected_version=expected_version)
    plugin_dirs = sorted(p for p in (repo_root / "plugins").iterdir() if p.is_dir())
    plugin_manifests = [directory / MANIFEST for directory in plugin_dirs]
    missing = [str(manifest) for manifest in plugin_manifests if not manifest.is_file()]
    assert not missing, f"missing plugin manifests: {missing}"
    assert plugin_manifests, "expected at least one plugin manifest"
    names = {}
    plugins = []
    for manifest in plugin_manifests:
        data = check_manifest(manifest, plugin=True, expected_version=expected_version)
        name = data["name"]
        assert "." not in name, (
            f"{manifest}: plugin name must not contain '.': {name!r}"
        )
        assert name not in names, (
            f"{manifest}: duplicate plugin name {name!r} (also {names.get(name)})"
        )
        names[name] = manifest
        plugins.append((manifest, data))
    for manifest, data in plugins:
        assert data["name"] == manifest.parent.name, (
            f"{manifest}: plugin name must match directory"
        )

    for manifest, data in [(repo_root / MANIFEST, root), *plugins]:
        for key in ("plugins", "conflicts"):
            if key in data:
                assert string_list(data[key]), f"{manifest}: invalid {key}"
                for name in data[key]:
                    assert name in names, (
                        f"{manifest}: unknown plugin in {key}: {name!r}"
                    )

    for manifest, data in plugins:
        plugin_dir = manifest.parent
        readme = plugin_dir / "README.md"
        assert readme.is_file() and readme.read_text(encoding="utf-8").strip(), (
            f"{plugin_dir}: missing plugin README.md"
        )
        news = plugin_dir / "NEWS.md"
        assert news.is_file(), f"{plugin_dir}: missing plugin NEWS.md"
        assert has_news_section(news.read_text(encoding="utf-8"), data["version"]), (
            f"{news}: NEWS.md missing section for version {data['version']!r}"
        )
        check_plugin_hooks(plugin_dir, data)

    check_renames_table(repo_root / "plugins.toml", set(names.keys()))
    check_third_party_notices(repo_root)
    print(f"{MANIFEST} checks passed (1 root + {len(plugin_manifests)} plugins)")


def check_third_party_notices(repo_root: pathlib.Path) -> None:
    """Every bundled .tmTheme file and inline plist theme must be listed in THIRD_PARTY_NOTICES.md."""
    themes_dir = repo_root / "themes"
    if not themes_dir.is_dir():
        return
    assets: list[str] = []
    syntax_dir = themes_dir / "syntax"
    if syntax_dir.is_dir():
        for path in sorted(syntax_dir.glob("*.tmTheme")):
            assets.append(path.relative_to(repo_root).as_posix())
    for path in sorted(themes_dir.glob("*.lua")):
        if "<plist" in path.read_text(encoding="utf-8", errors="replace"):
            assets.append(path.relative_to(repo_root).as_posix())
    if not assets:
        return
    notices_path = repo_root / "THIRD_PARTY_NOTICES.md"
    assert notices_path.is_file(), f"{notices_path}: missing THIRD_PARTY_NOTICES.md"
    notices = notices_path.read_text(encoding="utf-8")
    for rel in assets:
        assert rel in notices, f"THIRD_PARTY_NOTICES.md missing third-party theme: {rel}"
    required_markers = ["Permission is hereby granted, free of charge"]
    if "themes/syntax/zenburn.tmTheme" in assets:
        required_markers.append("Redistribution and use in source and binary forms")
    if "themes/github.lua" in assets:
        required_markers.append("DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE")
    for marker in required_markers:
        assert marker in notices, (
            f"THIRD_PARTY_NOTICES.md missing license text marker: {marker}"
        )


def has_news_section(text: str, version: str) -> bool:
    """Mirror mare's news.lua section(text, version) extraction."""
    body: list[str] = []
    in_section = False
    for line in text.splitlines():
        match = re.match(r"^##\s+v?([A-Za-z0-9._-]+)", line)
        if match:
            if in_section:
                break
            in_section = match.group(1) == version
        elif in_section:
            body.append(line)
    return bool("\n".join(body).strip())


def check_plugin_hooks(plugin_dir: pathlib.Path, data: dict) -> None:
    """Every static bus/policy event literal subscribed by a plugin must be listed in [provides].hooks."""
    lua_files = sorted(plugin_dir.rglob("*.lua"))
    if not lua_files:
        return
    declared = set((data.get("provides") or {}).get("hooks") or [])
    patterns = (
        re.compile(r"""(?:ctx|self\.ctx|s\.ctx):on\(\s*["']([^"']+)["']"""),
        re.compile(r"""policy:(?:voter|rewriter)\(\s*["']([^"']+)["']"""),
    )
    subscribed: set[str] = set()
    for path in lua_files:
        text = path.read_text(encoding="utf-8")
        for pat in patterns:
            subscribed.update(pat.findall(text))
    missing = sorted(subscribed - declared)
    assert not missing, (
        f"{plugin_dir / MANIFEST}: [provides].hooks missing subscribed events {missing}"
    )


def check_renames_table(path: pathlib.Path, active_plugins: set[str]) -> None:
    assert path.is_file(), f"{path}: missing plugins.toml"
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    unknown = set(data.keys()) - {"renamed", "deprecated"}
    assert not unknown, f"{path}: unsupported plugins.toml sections {sorted(unknown)}"
    for section in ("renamed", "deprecated"):
        if section not in data:
            continue
        table = data[section]
        assert isinstance(table, dict), f"{path}: [{section}] must be a table"
        for old_name, target in table.items():
            assert isinstance(old_name, str) and old_name.strip(), (
                f"{path}: invalid key in [{section}]: {old_name!r}"
            )
            assert isinstance(target, str) and target.strip(), (
                f"{path}: invalid value for {old_name!r} in [{section}]"
            )
            assert old_name not in active_plugins, (
                f"{path}: [{section}] key {old_name!r} conflicts with active plugin"
            )
            if section == "renamed":
                assert target in active_plugins, (
                    f"{path}: [renamed] {old_name!r} points to unknown target plugin {target!r}"
                )


if __name__ == "__main__":
    main()
