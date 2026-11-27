"""Shared helpers for e2e drivers that probe what the core under test ships."""

import subprocess
from pathlib import Path


def has_builtin_plugin(bin_path, name, env):
    """Whether this core ships a built-in plugin (read from `mare runtime`'s plugin copies)."""
    out = subprocess.run([str(bin_path), "runtime"], capture_output=True, text=True, env=env, check=True, encoding="utf-8")
    return (Path(out.stdout.strip().splitlines()[-1]) / "plugins" / f"{name}.lua").exists()
