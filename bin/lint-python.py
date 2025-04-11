#!/usr/bin/env python3
# filepath: /home/tfras/github/baofinance/bao-base/bin/lint-python.py
"""Lint Python files with ruff."""
import argparse
import subprocess
import sys


def main():
    """Run ruff linter on project Python files."""
    # Set up command line argument parsing
    parser = argparse.ArgumentParser(description="Lint Python files using ruff")
    parser.add_argument(
        "paths",
        nargs="*",
        default=["."],
        help="Paths to lint (default: current directory)",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Automatically fix issues when possible",
    )
    parser.add_argument(
        "--select",
        help="Select specific rule codes to enable (comma-separated)",
    )
    parser.add_argument(
        "--exclude",
        help="Exclude specific rule codes (comma-separated)",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Increase verbosity",
    )

    args = parser.parse_args()

    print(f"Linting Python files in: {', '.join(args.paths)}")

    # Build command with arguments
    cmd = ["python", "-m", "ruff", "check"]

    if args.fix:
        cmd.append("--fix")

    if args.select:
        cmd.extend(["--select", args.select])

    if args.exclude:
        cmd.extend(["--ignore", args.exclude])

    if args.verbose:
        cmd.append("--verbose")

    cmd.extend(args.paths)

    # Run ruff for linting
    try:
        if args.verbose:
            print(f"Running command: {' '.join(cmd)}")

        result = subprocess.run(cmd, check=True, text=True)
        return result.returncode
    except subprocess.CalledProcessError as e:
        print(f"Linting failed: {e}", file=sys.stderr)
        return e.returncode


if __name__ == "__main__":
    sys.exit(main())
