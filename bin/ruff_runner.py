"""Find and run the bao-base project's ruff - the one resolver shared by the `fmt-python` /
`lint-python` wrappers, so "which ruff" lives in a single place.

Ruff is the one in the bao-base root `.venv` (materialised by `uv sync`), the single ruff the editor
also uses (via `ruff.path`), so the CLI and the editor share one ruff version AND one config (the root
`[tool.ruff]`). The `format`/`check` subcommand and any flags are the caller's; this just runs whatever
ruff invocation it is handed.

Named `ruff_runner`, not `ruff`: `bin/` is on `sys.path`, so a `ruff.py` here would shadow the `ruff`
package in the venv's site-packages (the ruff distribution ships a Python launcher module alongside
its binary) on `import ruff` - the same file-shadows-package trap that broke a `slither.py` attempt.
"""

import subprocess
import sys
from pathlib import Path

DEFAULT_PATHS = ("bin", "script", "scripts", "test", "tests")


def default_paths() -> list[str]:
    """The conventional source dirs (relative to the cwd) that exist - fmt-python / lint-python's
    default scan scope when no paths are given, so neither wrapper nor any consumer's package.json
    repeats them. The candidate list is the union across bao-base-style repos (bao-base uses bin/test;
    consumers may add script/scripts/tests); each repo contributes only the dirs it actually has."""
    return [directory for directory in DEFAULT_PATHS if Path(directory).is_dir()]


def run(*args: str) -> int:
    """Run the bao-base ruff with `args`; return its exit code (or 1 if ruff has not been synced)."""
    ruff = Path(__file__).resolve().parent.parent / ".venv" / "bin" / "ruff"
    if not ruff.exists():
        sys.stderr.write(f"ruff not found at {ruff} - run `uv sync` in bao-base first.\n")
        return 1
    return subprocess.run([str(ruff), *args]).returncode
