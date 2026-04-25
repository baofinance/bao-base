#!/usr/bin/env bash
set -e
set -o pipefail
trap 'exit 130' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BAO_BASE_DIR="${BAO_BASE_DIR:-"$SCRIPT_DIR/../.."}"
RESULTS_DIR="$BAO_BASE_DIR/results"

mkdir -p "$RESULTS_DIR"
OUTPUT_FILE="$RESULTS_DIR/ci-debug-output.txt"

"$BAO_BASE_DIR/bin/ci" --debug 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "=== debug output saved to $OUTPUT_FILE ==="
