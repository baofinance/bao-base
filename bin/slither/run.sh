#!/usr/bin/env bash
set -euo pipefail

# This script acts as the wrapper for slither execution, replacing the previous bin/slither script
# It applies the standard configuration options and forwards arguments correctly

debug "Starting slither wrapper script"

# Pass all arguments to slither, plus our standard configuration options
debug "Running slither with standard configuration plus user arguments"

# shellcheck disable=SC2154 # we don't need to check if the variable is set
"$BAO_BASE_BIN_DIR"/run-python slither "$@" --config "$BAO_BASE_DIR/slither.config.json" --exclude-dependencies --fail-pedantic
