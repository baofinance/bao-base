#!/usr/bin/env bash
set -euo pipefail

arg=${1:-.}

# shellcheck disable=SC2154 # we don't need to check if the variable is set
log "slither v$("$BAO_BASE_BIN_DIR"/run-python slither --version)"
export FOUNDRY_PROFILE=novyper
"$BAO_BASE_BIN_DIR"/run-python slither "$arg" --config "$BAO_BASE_DIR/slither.config.json" --exclude-dependencies --fail-pedantic
