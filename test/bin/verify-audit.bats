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

@test "renamed file with name+NatSpec change clears via bytecode equivalence" {
  _new_fixture
  # A realistically-sized contract so git pairs the rename (>50% similar); only
  # the contract name and one NatSpec line differ between the two versions.
  cat >"$FIX/src/Old.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice old docs
contract Old {
    uint256 public constant A = 1;
    uint256 public constant B = 2;
    function f() external pure returns (uint256) { return 7; }
    function g() external pure returns (uint256) { return A + B; }
    function h(uint256 x) external pure returns (uint256) { return x * 2; }
}
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" mv src/Old.sol src/New.sol
  cat >"$FIX/src/New.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice new docs
contract New {
    uint256 public constant A = 1;
    uint256 public constant B = 2;
    function f() external pure returns (uint256) { return 7; }
    function g() external pure returns (uint256) { return A + B; }
    function h(uint256 x) external pure returns (uint256) { return x * 2; }
}
SOL
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  # rename + contract-name + NatSpec change, identical logic -> same creation
  # bytecode (metadata off) -> cleared.
  [ "$status" -eq 0 ]
  [[ "$output" == *"bytecode-equivalent"* ]]
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

@test "comment/whitespace-only change clears via bytecode equivalence" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo {
    function f() external pure returns (uint256) { return 1; }
}
SOL
  _tag_fixture "deploy/test"
  # add a comment line + reindent (formatting/comments never affect bytecode)
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
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bytecode-equivalent"* ]]
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

# ----------------------------------------------------------------------------
# BEHAVIOUR — build + bytecode signature (unit; compiles real fixtures)
# ----------------------------------------------------------------------------

@test "_file_signature: pure rename yields identical creation-bytecode signature" {
  source "$VERIFY_AUDIT" BATS   # BATS sentinel: load functions, don't run main
  _new_fixture
  cat >"$FIX/src/Old.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Old { function f() external pure returns (uint256) { return 7; } }
SOL
  ( cd "$FIX" && git add -A && git commit -q -m s && git tag deploy/test )
  ( cd "$FIX" && git mv src/Old.sol src/New.sol )
  sed -i 's/contract Old/contract New/' "$FIX/src/New.sol"
  ( cd "$FIX" && git add -A && git commit -q -m r )

  cd "$FIX"
  _wt=""; _wt_out=""; head_out=$(mktemp -d)
  _build_head_out "$head_out" src/New.sol
  _ensure_worktree
  _overlay_and_build_tag deploy/test src/Old.sol
  sig_old=$(_file_signature "$_wt_out" src/Old.sol)
  sig_new=$(_file_signature "$head_out" src/New.sol)
  _restore_overlay src/Old.sol
  echo "old=$sig_old"; echo "new=$sig_new"
  [ -n "$sig_old" ] && [ "$sig_old" != "__MISSING__" ]
  [ "$sig_old" == "$sig_new" ]
  git worktree remove --force "$_wt" 2>/dev/null
  rm -rf "$head_out" "$_wt_out"
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — rename hardening + negative/edge cases
# ----------------------------------------------------------------------------

@test "renames are paired despite hostile git config (renames off, low limit)" {
  _new_fixture
  git -C "$FIX" config diff.renames false
  git -C "$FIX" config diff.renameLimit 1
  cat >"$FIX/src/One.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract One {
    uint256 public constant A = 1;
    function f() external pure returns (uint256) { return 11; }
    function g(uint256 x) external pure returns (uint256) { return x + A; }
}
SOL
  cat >"$FIX/src/Two.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Two {
    uint256 public constant B = 2;
    function f() external pure returns (uint256) { return 22; }
    function g(uint256 x) external pure returns (uint256) { return x + B; }
}
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" mv src/One.sol src/OneRenamed.sol
  git -C "$FIX" mv src/Two.sol src/TwoRenamed.sol
  sed -i 's/contract One /contract OneRenamed /' "$FIX/src/OneRenamed.sol"
  sed -i 's/contract Two /contract TwoRenamed /' "$FIX/src/TwoRenamed.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename2

  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/OneRenamed.sol (cleared: bytecode-equivalent)"* ]]
  [[ "$output" == *"src/TwoRenamed.sol (cleared: bytecode-equivalent)"* ]]
}

@test "constructor-only change fails (creation bytecode, not runtime)" {
  _new_fixture
  cat >"$FIX/src/Imm.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Imm {
    uint256 public immutable X;
    constructor() { X = 1; }
    function f() external view returns (uint256) { return X; }
}
SOL
  _tag_fixture "deploy/test"
  sed -i 's/X = 1;/X = 2;/' "$FIX/src/Imm.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m ctor
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  # runtime bytecode is identical (immutable placeholder); creation bytecode
  # differs (constructor pushes 2 vs 1) -> not cleared. Proves we compare creation.
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGED (not ignored)"* ]]
}

@test "uncompilable tag version is a loud error, not a silent pass" {
  _new_fixture
  cat >"$FIX/src/Bad.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Bad { this is not valid solidity }
SOL
  _tag_fixture "deploy/test"
  cat >"$FIX/src/Bad.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Bad { function f() external pure returns (uint256) { return 1; } }
SOL
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m fix
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build at"* ]]
}

@test "deleting a deployed contract is reported as drift, not cleared" {
  _new_fixture
  cat >"$FIX/src/Gone.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Gone { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" rm -q src/Gone.sol && git -C "$FIX" commit -q -m del
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGED (not ignored)"* ]]
  [[ "$output" == *"src/Gone.sol"* ]]
}

@test "a tag's compiler settings cannot drift the comparison (overlay uses HEAD's)" {
  _new_fixture
  # tag's foundry.toml has via_ir off; HEAD has via_ir on. Same logic + a neutral
  # comment change. The overlay builds the tag's file inside the HEAD worktree, so
  # HEAD's foundry.toml is used for both and the tag's settings are ignored ->
  # both compile identically -> cleared.
  printf '[profile.default]\nsrc = "src"\nout = "out"\nvia_ir = false\noptimizer = true\n' >"$FIX/foundry.toml"
  cat >"$FIX/src/Loop.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Loop {
    function sum(uint256 n) external pure returns (uint256 s) {
        for (uint256 i = 0; i < n; ++i) {
            s += i * 2 + 1;
        }
    }
}
SOL
  _tag_fixture "deploy/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\nvia_ir = true\noptimizer = true\n' >"$FIX/foundry.toml"
  sed -i '2a // pinned-settings test' "$FIX/src/Loop.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m settings+comment
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bytecode-equivalent"* ]]
}

@test "control: differing settings DO change bytecode (keeps the pinning test honest)" {
  # If this fails, via_ir no longer affects this contract and the settings-pinning
  # test above would be passing vacuously. Pass condition = the signatures DIFFER.
  source "$VERIFY_AUDIT" BATS
  _new_fixture
  cat >"$FIX/src/Loop.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Loop {
    function sum(uint256 n) external pure returns (uint256 s) {
        for (uint256 i = 0; i < n; ++i) {
            s += i * 2 + 1;
        }
    }
}
SOL
  cd "$FIX"
  o1=$(mktemp -d); o2=$(mktemp -d)
  FOUNDRY_VIA_IR=false _build_head_out "$o1" src/Loop.sol
  FOUNDRY_VIA_IR=true _build_head_out "$o2" src/Loop.sol
  s1=$(_file_signature "$o1" src/Loop.sol)
  s2=$(_file_signature "$o2" src/Loop.sol)
  echo "via_ir=false len=${#s1}  via_ir=true len=${#s2}"
  [ -n "$s1" ] && [ "$s1" != "__MISSING__" ]
  [ "$s1" != "$s2" ]
  rm -rf "$o1" "$o2"
}

@test "shared worktree is reused correctly across multiple (chronological) tags" {
  _new_fixture
  cat >"$FIX/src/Alpha.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Alpha {
    uint256 public constant K = 3;
    function f(uint256 x) external pure returns (uint256) { return x + K; }
}
SOL
  _tag_fixture "deploy/early"
  cat >"$FIX/src/Beta.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Beta {
    uint256 public constant K = 5;
    function f(uint256 x) external pure returns (uint256) { return x * K; }
}
SOL
  _tag_fixture "deploy/late"
  # neutral renames at HEAD of both contracts (name only)
  git -C "$FIX" mv src/Alpha.sol src/AlphaV2.sol
  git -C "$FIX" mv src/Beta.sol src/BetaV2.sol
  sed -i 's/contract Alpha /contract AlphaV2 /' "$FIX/src/AlphaV2.sol"
  sed -i 's/contract Beta /contract BetaV2 /' "$FIX/src/BetaV2.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m renames
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/*"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/AlphaV2.sol (cleared: bytecode-equivalent)"* ]]
  [[ "$output" == *"src/BetaV2.sol (cleared: bytecode-equivalent)"* ]]
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — redundant ignore-entry detection (entry that would now clear)
# ----------------------------------------------------------------------------

@test "ignore entry for a would-now-clear file is flagged redundant (remove it)" {
  _new_fixture
  cat >"$FIX/src/Widget.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Widget {
    uint256 public constant K = 9;
    function f(uint256 x) external pure returns (uint256) { return x + K; }
    function g(uint256 x) external pure returns (uint256) { return x * K; }
}
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" mv src/Widget.sol src/WidgetV2.sol
  sed -i 's/contract Widget /contract WidgetV2 /' "$FIX/src/WidgetV2.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename
  printf 'deploy/test src/WidgetV2.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/WidgetV2.sol"* ]]
  [[ "$output" == *"would now clear"* ]]
}

@test "ignore entry for a genuinely-changed file is kept, not flagged" {
  _new_fixture
  cat >"$FIX/src/Widget.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Widget {
    function f() external pure returns (uint256) { return 1; }
}
SOL
  _tag_fixture "deploy/test"
  sed -i 's/return 1;/return 2;/' "$FIX/src/Widget.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  printf 'deploy/test src/Widget.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored via .verify-audit-ignore"* ]]
  [[ "$output" != *"would now clear"* ]]
}

@test "ignore entry that suppresses a deletion is kept (not built, not flagged)" {
  _new_fixture
  cat >"$FIX/src/Gone.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Gone { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  git -C "$FIX" rm -q src/Gone.sol && git -C "$FIX" commit -q -m del
  printf 'deploy/test src/Gone.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  # a deleted file cannot be built; the entry legitimately suppresses real drift,
  # so it must stay "ignored via" and never be flagged as a redundant entry.
  run "$VERIFY_AUDIT" "deploy/test"
  echo "status=$status"; echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/Gone.sol (ignored via .verify-audit-ignore)"* ]]
  [[ "$output" != *"would now clear"* ]]
}
