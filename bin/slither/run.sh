#!/usr/bin/env bash
set -euo pipefail

# Both are set by `run`, which sources this. Assert rather than assume: unset, they would expand to
# an empty string and silently address the wrong paths.
: "${BAO_BASE_BIN_DIR:?must be set by the bao-base run script}"
: "${BAO_BASE_DIR:?must be set by the bao-base run script}"

# Fix hash randomisation so slither's analysis is deterministic across platforms
export PYTHONHASHSEED=0
# a version banner: if slither cannot report its version the real invocation below fails anyway
log "slither v$("$BAO_BASE_BIN_DIR"/run-python slither --version)" # lint-bash disable=command-substitution
# crytic_compile's is_dependency() checks "lib" in Path(absolute_path).parts, which incorrectly
# suppresses all findings when the project root is itself under a directory named "lib" (e.g. as
# a git submodule). Replace --exclude-dependencies with an anchored filter-paths instead.
# realpath of the current directory, which the shell is already in, so there is no failure to check
"$BAO_BASE_BIN_DIR"/run-python slither . --config "$BAO_BASE_DIR/slither.config.json" --filter-paths "BaoFixedOwnable,$(realpath .)/lib" --fail-pedantic "$@" # lint-bash disable=command-substitution
