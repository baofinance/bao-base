#!/usr/bin/env python3
# filepath: /home/tfras/github/baofinance/bao-base/bin/python-format.py
"""Format Python files with black and isort."""
import os
import subprocess
import sys
from pathlib import Path


def main():
    """Run black and isort on project Python files."""
    project_root = Path(os.environ.get("BAO_BASE_DIR", "."))

    paths = sys.argv[1:] or ["."]
    paths = [str(project_root / path) for path in paths]

    print(f"Formatting Python files in: {', '.join(paths)}")

    # Run black for formatting
    try:
        subprocess.run(["python", "-m", "black"] + paths, check=True, text=True)

        # Run isort for import sorting
        subprocess.run(["python", "-m", "isort"] + paths, check=True, text=True)

        return 0
    except subprocess.CalledProcessError as e:
        print(f"Formatting failed: {e}", file=sys.stderr)
        return e.returncode


if __name__ == "__main__":
    sys.exit(main())
