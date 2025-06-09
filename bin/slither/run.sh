#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2154 # we don't need to check if the variable is set
"$BAO_BASE_BIN_DIR"/run-python slither --version
"$BAO_BASE_BIN_DIR"/run-python slither "$@" --config "$BAO_BASE_DIR/slither.config.json" --exclude-dependencies --fail-pedantic
