#!/usr/bin/env bash
set -euo pipefail

# Both are set by `run`, which sources this. Assert rather than assume: unset, they would expand to
# an empty string and silently address the wrong paths.
: "${BAO_BASE_BIN_DIR:?must be set by the bao-base run script}"
: "${BAO_BASE_DIR:?must be set by the bao-base run script}"

# Fix hash randomisation so slither's analysis is deterministic across platforms
export PYTHONHASHSEED=0

# Build into dedicated out AND cache directories, emptied first. Three things depend on this:
#  - crytic_compile runs `forge clean` before building, and `forge clean` removes BOTH the out and the
#    cache directory - so redirecting out alone still destroys the developer's incremental build,
#    because the cache is what makes it incremental;
#  - the contract-name check below reads build-info, which forge NEVER prunes, so a shared directory
#    accumulates entries for files that have since moved and would report them as collisions;
#  - each sits UNDER the directory the repo already ignores (`out/`, `cache/`), so no consuming repo
#    needs a .gitignore change - which is exactly the per-repo wiring this script exists to avoid.
# build_info_path defaults to <out>/build-info, so redirecting out carries build-info with it.
export FOUNDRY_OUT="out/_slither"
export FOUNDRY_CACHE_PATH="cache/_slither"
rm -rf "$FOUNDRY_OUT" "$FOUNDRY_CACHE_PATH"
# a version banner: if slither cannot report its version the real invocation below fails anyway
log "slither v$("$BAO_BASE_BIN_DIR"/run-python slither --version)" # lint-bash disable=command-substitution
# crytic_compile's is_dependency() checks "lib" in Path(absolute_path).parts, which incorrectly
# suppresses all findings when the project root is itself under a directory named "lib" (e.g. as
# a git submodule). Replace --exclude-dependencies with an anchored filter-paths instead.
#
# --foundry-out-directory must be given the SAME directory as FOUNDRY_OUT above. crytic_compile builds
# via `forge build`, which honours FOUNDRY_OUT, but then reads the artifacts back from
# `kwargs.get("foundry_out_directory", "out")` (crytic_compile/platform/foundry.py) - it never asks
# forge where the build went. Setting only the env var therefore builds into one directory and reads
# from another, and slither dies with "out/build-info is not a directory".
# realpath of the current directory, which the shell is already in, so there is no failure to check
slither_status=0
"$BAO_BASE_BIN_DIR"/run-python slither . --config "$BAO_BASE_DIR/slither.config.json" --foundry-out-directory "$FOUNDRY_OUT" --filter-paths "BaoFixedOwnable,$(realpath .)/lib" --fail-pedantic "$@" || slither_status=$? # lint-bash disable=command-substitution

# Two source files compiling one contract name is silent everywhere else: forge writes both to
# out/<file>.sol/<Contract>.json so the second overwrites the first, and slither's own name-reused
# detector reports nothing (measured: 0 findings against 11 real collisions). build-info keys
# contracts by SOURCE PATH, so both declarations survive there. It rides along here because slither
# has just done the clean build it needs - and because living in a shared bin script is what makes it
# run in every consuming repo, rather than needing a line added to each one's package.json.
names_status=0
"$BAO_BASE_BIN_DIR"/run-python lint-contract-names.py "$FOUNDRY_OUT/build-info" || names_status=$?

# Report both, then fail with slither's code if it failed, else the check's. Deliberately not `set -e`
# after slither: a repo with slither findings would otherwise never learn it also has a name collision.
worst_status=$slither_status
if [[ $worst_status -eq 0 ]]; then
  worst_status=$names_status
fi
(exit "$worst_status")
