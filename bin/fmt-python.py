#!/usr/bin/env python3
"""Format the Python bin scripts and tests with ruff's formatter (black-compatible).

`run fmt-python [paths...] [--check | --write] [ruff flags...]` over the given paths (default: the
`bin` and `test` trees):
  --write   format the files in place
  --check   report which files are not formatted and change nothing (the default, so a bare run is
            safe and CI-usable)

Ruff is the bao-base project's own - its root `.venv` (materialised by `uv sync`), the single ruff
the editor also uses (via `ruff.path`). The formatting RULES come from that project's root
`[tool.ruff]`, so this CLI and the editor share one ruff version AND one config. Ruff's exit status is
returned, so an unformatted file fails a `--check` run.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ruff_runner  # noqa: E402 - importable only after bin is on the path above

DEFAULT_PATHS = ("bin", "test")


def main():
    args = sys.argv[1:]
    paths = [arg for arg in args if not arg.startswith("-")] or list(DEFAULT_PATHS)
    passthrough = [arg for arg in args if arg.startswith("-") and arg not in ("--write", "--check")]
    # --write formats in place; anything else (--check, or no mode flag) only reports, changing nothing.
    mode = [] if "--write" in args else ["--check"]
    return ruff_runner.run("format", *mode, *passthrough, *paths)


if __name__ == "__main__":
    sys.exit(main())
