#!/usr/bin/env bats
#
# Characterization + behaviour tests for bin/verify-audit.
#
# The first block (CHARACTERIZATION) pins the behaviour of the script *as it is
# today*, before the bytecode-equivalence work. They are green against the
# current code. As the staged clear is added, some are expected to flip — each
# flip is judged: an intended behaviour change (update the test) or a regression
# (fix the code). Tests marked "EXPECTED TO FLIP" are the intended changes.

VERIFY_AUDIT="$PWD/bin/verify-audit"

# Build a self-contained foundry git repo with an `origin` remote (so the
# script's `git fetch --tags` succeeds). Leaves $FIX as the working repo dir.
_new_fixture() {
  FIX=$(mktemp -d)
  BARE_PARENT=$(mktemp -d)
  BARE="$BARE_PARENT/origin.git"
  git init -q --bare "$BARE"
  git -C "$FIX" init -q
  git -C "$FIX" config user.email t@t
  git -C "$FIX" config user.name test
  git -C "$FIX" remote add origin "$BARE"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n' >"$FIX/foundry.toml"
  mkdir -p "$FIX/src"
}

# Commit the current state, tag it, and push so `git fetch --tags` works.
_tag_fixture() { # $1 = tag
  git -C "$FIX" add -A
  git -C "$FIX" commit -q -m snapshot
  git -C "$FIX" tag "$1"
  git -C "$FIX" push -q origin HEAD --tags 2>/dev/null
}

teardown() {
  [[ -n "${FIX:-}" ]] && rm -rf "$FIX"
  [[ -n "${BARE_PARENT:-}" ]] && rm -rf "$BARE_PARENT"
  return 0   # never let cleanup short-circuit a unit test that made no fixture
}

# ----------------------------------------------------------------------------
# CHARACTERIZATION — current behaviour
# ----------------------------------------------------------------------------

@test "char: no changes under src is green" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes under src"* ]]
}

@test "char: plain modification (no ignore) is reported as CHANGED" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  sed -i 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGED (not ignored)"* ]]
}

@test "char: renamed file, import-line-only change is auto-suppressed" {
  _new_fixture
  cat >"$FIX/src/dep1.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
SOL
  cat >"$FIX/src/dep2.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
SOL
  cat >"$FIX/src/Old.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./dep1.sol";
contract Old { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" mv src/Old.sol src/New.sol
  sed -i 's#import "./dep1.sol";#import "./dep2.sol";#' "$FIX/src/New.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m reimport
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-suppressed"* || "$output" == *"cleared"* ]]
}

@test "char: renamed file with non-import change FAILS today [EXPECTED TO FLIP to cleared]" {
  _new_fixture
  cat >"$FIX/src/Old.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice old docs
contract Old { function f() external pure returns (uint256) { return 7; } }
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" mv src/Old.sol src/New.sol
  cat >"$FIX/src/New.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice new docs
contract New { function f() external pure returns (uint256) { return 7; } }
SOL
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  # Current behaviour: non-import change in a rename is not suppressed -> fails.
  # After Stage 2 this becomes bytecode-equivalent and clears (status 0).
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGED (not ignored)"* ]]
}

@test "char: whole-tag ignore suppresses the tag" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  sed -i 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  printf 'deploy/test\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored via .verify-audit-ignore"* ]]
}

@test "char: file-level ignore suppresses the named file" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  sed -i 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  printf 'deploy/test src/Foo.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/Foo.sol (ignored via .verify-audit-ignore)"* ]]
}

@test "char: stale whole-tag ignore entry errors" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  # no changes, but the tag is whole-ignored -> stale
  printf 'deploy/test\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale .verify-audit-ignore entry"* ]]
}

@test "char: stale file-level ignore entry errors" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  sed -i 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  # Foo.sol legitimately ignored; Ghost.sol never changed -> stale entry.
  printf 'deploy/test src/Foo.sol src/Ghost.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale .verify-audit-ignore entry: \"src/Ghost.sol\""* ]]
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — Stage 1 textual clear
# ----------------------------------------------------------------------------

@test "comment/whitespace-only change is cleared without a build" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo {
    function f() external pure returns (uint256) { return 1; }
}
SOL
  _tag_fixture "deploy/test"
  # add a comment line + reindent existing lines (no line splits/merges)
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// a brand new explanatory comment
contract Foo {
        function f() external pure returns (uint256) { return 1; }
}
SOL
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m comment+reindent

  cd "$FIX"
  # forge shim that errors if called, to prove Stage 1 does not build.
  shim=$(mktemp -d)
  printf '#!/bin/sh\necho FORGE_CALLED >&2\nexit 1\n' >"$shim/forge"
  chmod +x "$shim/forge"
  PATH="$shim:$PATH" run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FORGE_CALLED"* ]]
  rm -rf "$shim"
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — metadata-disabled guard (unit; sourced with BATS sentinel)
# ----------------------------------------------------------------------------

@test "_assert_metadata_disabled trips when forge config does not show none/false" {
  source "$VERIFY_AUDIT" BATS   # BATS sentinel: load functions, don't run main
  shim=$(mktemp -d)
  printf '#!/bin/sh\necho '\''bytecode_hash = "ipfs"'\''\necho '\''cbor_metadata = true'\''\n' >"$shim/forge"
  chmod +x "$shim/forge"
  PATH="$shim:$PATH" run _assert_metadata_disabled
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"metadata not disabled"* ]]
  rm -rf "$shim"
}

@test "_assert_metadata_disabled passes when forge config shows none/false" {
  source "$VERIFY_AUDIT" BATS   # BATS sentinel: load functions, don't run main
  shim=$(mktemp -d)
  printf '#!/bin/sh\necho '\''bytecode_hash = "none"'\''\necho '\''cbor_metadata = false'\''\n' >"$shim/forge"
  chmod +x "$shim/forge"
  PATH="$shim:$PATH" run _assert_metadata_disabled
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  rm -rf "$shim"
}
