#!/usr/bin/env python3
"""Run pytest in bao-base's Python environment, with the arguments as typed.

pytest reads each path from the folder it is typed in, and takes its test paths from the project's configuration
(`testpaths` in pyproject.toml) when given none. So every argument goes to pytest unchanged, and the only one added
is `-v`, when no verbosity is given."""

import subprocess
import sys


def main() -> int:
    """Run pytest with this script's arguments, and return its exit status."""
    args = sys.argv[1:]
    if not any(arg.startswith("-v") for arg in args):
        args = ["-v", *args]

    print(f"Running pytest with args: {' '.join(args)}")

    # pytest runs in a new interpreter, not through its Python API: this script is named pytest.py, so importing
    # pytest from here would import this script.
    return subprocess.run(["python3", "-m", "pytest", *args], check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
