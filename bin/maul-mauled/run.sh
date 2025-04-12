#!/usr/bin/env bash
set -euo pipefail

# Configure Python paths - ensure bin/maul is importable
# This ordering is critical for Python to find packages correctly
export PYTHONPATH="$BAO_BASE_DIR:$BAO_BASE_BIN_DIR"

# Execute using the correct module path
python3 -m bin.maul "$@"
