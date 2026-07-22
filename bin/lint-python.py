#!/usr/bin/env python3
"""Lint the Python bin scripts and tests with ruff.

`run lint-python [paths...] [ruff flags...]` runs `ruff check` over the given paths (default: the
conventional source dirs that exist here - see ruff_runner.default_paths). Ruff is the bao-base
project's own - its root `.venv` (materialised by `uv sync`), the single ruff the editor also uses -
so version and config are shared. Ruff's exit
status is returned, so a lint failure fails the run; `--fix` and any other ruff flags pass straight through.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ruff_runner  # noqa: E402 - importable only after bin is on the path above


def main():
    args = sys.argv[1:]
    paths = [arg for arg in args if not arg.startswith("-")] or ruff_runner.default_paths()
    flags = [arg for arg in args if arg.startswith("-")]
    return ruff_runner.run("check", *paths, *flags)


if __name__ == "__main__":
    sys.exit(main())
