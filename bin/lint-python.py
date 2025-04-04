#!/usr/bin/env python3
# filepath: /home/tfras/github/baofinance/bao-base/bin/python-lint.py
"""Lint Python files with ruff."""
import os
import sys
import subprocess
from pathlib import Path

def main():
    """Run ruff linter on project Python files."""
    project_root = Path(os.environ.get('BAO_BASE_DIR', '.'))

    # Default paths to check if none provided
    paths = sys.argv[1:] or ['.']
    paths = [str(project_root / path) for path in paths]

    print(f"Linting Python files in: {', '.join(paths)}")

    # Run ruff for linting
    try:
        result = subprocess.run(
            ["python", "-m", "ruff", "check"] + paths,
            check=True,
            text=True
        )
        return result.returncode
    except subprocess.CalledProcessError as e:
        print(f"Linting failed: {e}", file=sys.stderr)
        return e.returncode

if __name__ == "__main__":
    sys.exit(main())