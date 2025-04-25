#!/usr/bin/env python3
"""Run pytest for the project with improved discovery and reporting."""

import os
import subprocess
import sys
from pathlib import Path


def main():
    """Run pytest with the given arguments."""
    # Find the project root (where .git is)
    project_root = Path(os.environ.get("BAO_BASE_DIR", "."))

    # Default test path if none provided
    args = sys.argv[1:] or ["test"]

    # Construct full paths for args that are directory/file paths
    full_args = []
    for arg in args:
        # Only modify args that look like paths and don't start with '-'
        if not arg.startswith("-") and not any(c in arg for c in "=:"):
            # Convert path to be relative to the project root
            arg_path = project_root / arg
            if arg_path.exists():
                full_args.append(str(arg_path))
            else:
                full_args.append(arg)
        else:
            full_args.append(arg)

    # Add sensible defaults if not specified
    if not any(arg.startswith("-v") for arg in full_args):
        full_args.insert(0, "-v")

    print(f"Running pytest with args: {' '.join(full_args)}")

    # Call pytest directly as a subprocess instead of using the Python API
    # This prevents recursion since our script is also named 'pytest.py'
    result = subprocess.run(["python3", "-m", "pytest"] + full_args, check=False)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
