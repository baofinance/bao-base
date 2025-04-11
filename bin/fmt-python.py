#!/usr/bin/env python3
# filepath: /home/tfras/github/baofinance/bao-base/bin/fmt-python.py
"""Format Python files with black and isort."""
import argparse
import os
import subprocess
import sys
from pathlib import Path


def main():
    """Run black and isort on project Python files."""
    # Parse command line arguments
    parser = argparse.ArgumentParser(
        description="Format Python files with black and isort"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--check", action="store_true", help="Check formatting without changing files"
    )
    group.add_argument("--write", action="store_true", help="Format files in-place")
    parser.add_argument(
        "paths", nargs="+", help="Paths to format (default: current directory)"
    )

    args = parser.parse_args()

    # Get project root and normalize paths
    project_root = Path(os.environ.get("BAO_BASE_DIR", "."))
    paths = args.paths or ["."]
    paths = [str(project_root / path) for path in paths]

    print(
        f"{'Checking' if args.check else 'Formatting'} Python files in: {', '.join(paths)}"
    )

    # Build command-line flags
    black_args = ["python", "-m", "black"]
    isort_args = ["python", "-m", "isort"]

    if args.check:
        black_args.append("--check")
        isort_args.append("--check-only")
        print("Check mode: files will not be modified")
    else:
        print("Write mode: files will be modified")

    # Run tools
    try:
        # Run black for formatting
        print("Running black...")
        black_result = subprocess.run(
            black_args + paths,
            check=False,  # Don't raise exception, we'll handle return code
            text=True,
            capture_output=True,
        )
        if black_result.stdout:
            print(black_result.stdout)
        if black_result.stderr:
            print(black_result.stderr, file=sys.stderr)

        # Run isort for import sorting
        print("Running isort...")
        isort_result = subprocess.run(
            isort_args + paths,
            check=False,  # Don't raise exception, we'll handle return code
            text=True,
            capture_output=True,
        )
        if isort_result.stdout:
            print(isort_result.stdout)
        if isort_result.stderr:
            print(isort_result.stderr, file=sys.stderr)

        # Return non-zero if either tool failed
        if black_result.returncode != 0 or isort_result.returncode != 0:
            return 1
        return 0

    except Exception as e:
        print(f"Error running formatters: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
