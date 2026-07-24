"""Find and run the bao-base project's ruff - the one resolver shared by the `fmt-python` /
`lint-python` wrappers, so "which ruff" lives in a single place.

Ruff comes from the bao-base ROOT project (its pyproject.toml owns the version AND the `[tool.ruff]`
config), auto-loaded on demand via `run-python --project <root>` — the same uv bootstrap every other
bao-base tool uses (and the same ruff the editor is wired to). The `format`/`check` subcommand and any
flags are the caller's; this just hands them to ruff.

Named `ruff_runner`, not `ruff`: `bin/` is on `sys.path`, so a `ruff.py` here would shadow the `ruff`
package in the venv's site-packages (the ruff distribution ships a Python launcher module alongside
its binary) on `import ruff` - the same file-shadows-package trap that broke a `slither.py` attempt.
"""

import subprocess
from pathlib import Path

DEFAULT_PATHS = ("bin", "script", "scripts", "test", "tests")


def default_paths() -> list[str]:
    """The conventional source dirs (relative to the cwd) that exist - fmt-python / lint-python's
    default scan scope when no paths are given, so neither wrapper nor any consumer's package.json
    repeats them. The candidate list is the union across bao-base-style repos (bao-base uses bin/test;
    consumers may add script/scripts/tests); each repo contributes only the dirs it actually has."""
    return [directory for directory in DEFAULT_PATHS if Path(directory).is_dir()]


def run(*args: str) -> int:
    """Run ruff from the bao-base ROOT project, auto-loaded via `run-python --project <root>` (the same
    uv bootstrap every other bao-base tool uses); return ruff's exit code."""
    bin_dir = Path(__file__).resolve().parent
    run_python = bin_dir / "run-python"
    return subprocess.run([str(run_python), "--project", str(bin_dir.parent), "ruff", *args]).returncode
