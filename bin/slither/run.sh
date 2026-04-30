#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2154 # we don't need to check if the variable is set
# Fix hash randomisation so slither's analysis is deterministic across platforms
export PYTHONHASHSEED=0
log "slither v$("$BAO_BASE_BIN_DIR"/run-python slither --version)"
# crytic_compile's is_dependency() checks "lib" in Path(absolute_path).parts, which incorrectly
# suppresses all findings when the project root is itself under a directory named "lib" (e.g. as
# a git submodule). Replace --exclude-dependencies with an anchored filter-paths instead.
"$BAO_BASE_BIN_DIR"/run-python slither . --config "$BAO_BASE_DIR/slither.config.json" --filter-paths "BaoFixedOwnable,$(realpath .)/lib" --fail-pedantic "$@"
