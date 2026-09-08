#!/usr/bin/env bats
#
# Characterization + behaviour tests for bin/verify-audit.
#
# The first block (CHARACTERIZATION) pins the behaviour of the script *as it is
# today*, before the bytecode-equivalence work. They are green against the
# current code. As the staged clear is added, some are expected to flip — each
# flip is judged: an intended behaviour change (update the test) or a regression
# (fix the code). Tests marked "EXPECTED TO FLIP" are the intended changes.

# Entered through `run`, as every script under bin/ is: `run` sources them, having exported the
# environment they reach other tools by (BAO_BASE_BIN_DIR, the logging functions). Executing the file
# directly leaves that unset, so verify-audit's dependency-version check cannot start - and the
# failure lands on whichever line reaches for it first, which says nothing about the test.
BAO_BASE_RUN="$PWD/run"

# The path itself, for the tests that source the file to reach a single function.
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

# Commit the current state and push it, leaving it untagged; echoes the commit
# SHA. The baseline for a repo that cuts no tags is the commit itself.
_commit_fixture() {
  git -C "$FIX" add -A
  git -C "$FIX" commit -q -m snapshot
  git -C "$FIX" push -q origin HEAD 2>/dev/null
  git -C "$FIX" rev-parse HEAD
}

# Edit a fixture file in place. GNU sed's `-i` takes no argument, whereas BSD
# (macOS) sed reads the very next argument as the backup suffix — so on macOS
# `sed -i 's/x/y/' file` binds the script as the suffix and then tries to parse
# the path as the script. No spelling of `-i` means "in place, no backup" on
# both, so write the result out and copy it back over the original.
_sed_inplace() { # $1 = sed script, $2 = file
  local script="$1" file="$2" tmp
  tmp="$(mktemp)"
  # Deliberately neither `sed ... >"$file"` (the redirect truncates the input
  # before sed reads it) nor an assignment from a command substitution (that
  # swallows sed's exit status, so a bad script would empty the file silently).
  sed "$script" "$file" >"$tmp"
  cat "$tmp" >"$file" # copy back rather than mv, so the original's mode survives
  rm -f "$tmp"
}

teardown() {
  [[ -n "${FIX:-}" ]] && rm -rf "$FIX"
  [[ -n "${BARE_PARENT:-}" ]] && rm -rf "$BARE_PARENT"
  return 0 # never let cleanup short-circuit a unit test that made no fixture
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's#import "./dep1.sol";#import "./dep2.sol";#' "$FIX/src/New.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m reimport
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  printf 'deploy/test\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  printf 'deploy/test src/Foo.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  # Foo.sol legitimately ignored; Ghost.sol never changed -> stale entry.
  printf 'deploy/test src/Foo.sol src/Ghost.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bytecode-equivalent"* ]]
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — metadata-disabled guard (unit; sourced with BATS sentinel)
# ----------------------------------------------------------------------------

@test "_assert_metadata_disabled trips when forge config does not show none/false" {
  # shellcheck source=bin/verify-audit
  source "$VERIFY_AUDIT" BATS # BATS sentinel: load functions, don't run main
  shim=$(mktemp -d)
  printf '#!/bin/sh\necho '\''bytecode_hash = "ipfs"'\''\necho '\''cbor_metadata = true'\''\n' >"$shim/forge"
  chmod +x "$shim/forge"
  PATH="$shim:$PATH" run _assert_metadata_disabled
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"metadata not disabled"* ]]
  rm -rf "$shim"
}

@test "_assert_metadata_disabled passes when forge config shows none/false" {
  # shellcheck source=bin/verify-audit
  source "$VERIFY_AUDIT" BATS # BATS sentinel: load functions, don't run main
  shim=$(mktemp -d)
  printf '#!/bin/sh\necho '\''bytecode_hash = "none"'\''\necho '\''cbor_metadata = false'\''\n' >"$shim/forge"
  chmod +x "$shim/forge"
  PATH="$shim:$PATH" run _assert_metadata_disabled
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  rm -rf "$shim"
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — build + bytecode signature (unit; compiles real fixtures)
# ----------------------------------------------------------------------------

@test "_file_signature: pure rename yields identical creation-bytecode signature" {
  # shellcheck source=bin/verify-audit
  source "$VERIFY_AUDIT" BATS # BATS sentinel: load functions, don't run main
  _new_fixture
  cat >"$FIX/src/Old.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Old { function f() external pure returns (uint256) { return 7; } }
SOL
  (cd "$FIX" && git add -A && git commit -q -m s && git tag deploy/test)
  (cd "$FIX" && git mv src/Old.sol src/New.sol)
  _sed_inplace 's/contract Old/contract New/' "$FIX/src/New.sol"
  (cd "$FIX" && git add -A && git commit -q -m r)

  cd "$FIX"
  _wt=""
  _wt_out=""
  head_out=$(mktemp -d)
  _build_head_out "$head_out" src/New.sol
  _ensure_worktree
  _overlay_and_build_revision deploy/test src/Old.sol -- src/Old.sol
  sig_old=$(_file_signature "$_wt_out" src/Old.sol)
  sig_new=$(_file_signature "$head_out" src/New.sol)
  _restore_overlay src/Old.sol
  echo "old=$sig_old"
  echo "new=$sig_new"
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
  _sed_inplace 's/contract One /contract OneRenamed /' "$FIX/src/OneRenamed.sol"
  _sed_inplace 's/contract Two /contract TwoRenamed /' "$FIX/src/TwoRenamed.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename2

  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/X = 1;/X = 2;/' "$FIX/src/Imm.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m ctor
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build at"* ]]
}

@test "a shallow clone is a loud error, not a silent pass" {
  # A shallow clone is missing an unknown subset of the tagged commits — the tag at the cloned tip
  # is present, older ones are not — so the patterns match only whatever happens to be there and the
  # audit reports success having checked a subset it never names. That is the worst outcome for a
  # check whose whole job is noticing drift, and it cannot be detected from the tag list itself.
  # The caller must fetch the full history (in GitHub Actions, fetch-depth: 0).
  _new_fixture
  cat >"$FIX/src/A.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract A { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  # cloned inside BARE_PARENT so teardown removes it with the rest of the fixture
  git clone -q --depth=1 "file://$BARE" "$BARE_PARENT/shallow"
  cd "$BARE_PARENT/shallow"
  run "$BAO_BASE_RUN" verify-audit
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *shallow* ]]
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  # a comment-only edit, so Loop.sol shows up in the diff and actually gets
  # compared. Appended rather than inserted with sed's `a` command: the one-line
  # `2a text` form is a GNU extension that BSD (macOS) sed rejects.
  printf '// pinned-settings test\n' >>"$FIX/src/Loop.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m settings+comment
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bytecode-equivalent"* ]]
}

@test "control: differing settings DO change bytecode (keeps the pinning test honest)" {
  # If this fails, via_ir no longer affects this contract and the settings-pinning
  # test above would be passing vacuously. Pass condition = the signatures DIFFER.
  # shellcheck source=bin/verify-audit
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
  o1=$(mktemp -d)
  o2=$(mktemp -d)
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
  _sed_inplace 's/contract Alpha /contract AlphaV2 /' "$FIX/src/AlphaV2.sol"
  _sed_inplace 's/contract Beta /contract BetaV2 /' "$FIX/src/BetaV2.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m renames
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/*"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/contract Widget /contract WidgetV2 /' "$FIX/src/WidgetV2.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename
  printf 'deploy/test src/WidgetV2.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Widget.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  printf 'deploy/test src/Widget.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
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
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/Gone.sol (ignored via .verify-audit-ignore)"* ]]
  [[ "$output" != *"would now clear"* ]]
}

# ----------------------------------------------------------------------------
# BEHAVIOUR — tag scope: "tag {dir ...}" restricts the diff to those directories
# ----------------------------------------------------------------------------

# helper: a fixture with src/a/X.sol and src/b/Y.sol, tagged deploy/test
_scope_fixture() {
  _new_fixture
  mkdir -p "$FIX/src/a" "$FIX/src/b"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract X { function f() external pure returns (uint256){ return 1; } }\n' >"$FIX/src/a/X.sol"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Y { function f() external pure returns (uint256){ return 1; } }\n' >"$FIX/src/b/Y.sol"
  _tag_fixture "deploy/test"
}

@test "tag scope restricts the diff: out-of-scope drift is not flagged" {
  _scope_fixture
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/b/Y.sol" # real change OUTSIDE scope
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change-b
  printf 'deploy/test {src/a}\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Y.sol"* ]]
}

@test "tag scope still flags in-scope drift" {
  _scope_fixture
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/a/X.sol" # real change INSIDE scope
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change-a
  printf 'deploy/test {src/a}\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/a/X.sol"* ]]
}

@test "ignore entry outside the declared scope is an error" {
  _scope_fixture
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/b/Y.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change-b
  printf 'deploy/test {src/a} src/b/Y.sol\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]] && [[ "$output" == *"scope"* ]]
}

@test "scope from a deployment manifest checks exactly the deployed contracts" {
  _new_fixture
  mkdir -p "$FIX/src/a" "$FIX/src/b" "$FIX/deployments"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract X { function f() external pure returns (uint256){ return 1; } }\n' >"$FIX/src/a/X.sol"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Y { function f() external pure returns (uint256){ return 1; } }\n' >"$FIX/src/b/Y.sol"
  # the manifest is part of the deploy, so it exists AT the tag
  printf '{"oracles":{"X":{"contractPath":"src/a/X.sol:X"}}}' >"$FIX/deployments/m.json"
  _tag_fixture "deploy/test"
  # change BOTH; only X is in the manifest
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/a/X.sol"
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/b/Y.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change-both
  printf 'deploy/test {deployments/m.json:contractPath}\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/a/X.sol"* ]] # deployed -> in scope -> flagged
  [[ "$output" != *"Y.sol"* ]]       # not deployed -> out of scope -> not checked
}

@test "scope from a manifest still pairs renamed deployed contracts (bytecode-equivalent)" {
  _new_fixture
  mkdir -p "$FIX/src/m" "$FIX/deployments"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Old {\n  uint256 public constant K = 3;\n  function f(uint256 x) external pure returns (uint256){ return x + K; }\n}\n' >"$FIX/src/m/Old.sol"
  printf '{"oracles":{"Old":{"contractPath":"src/m/Old.sol:Old"}}}' >"$FIX/deployments/m.json"
  _tag_fixture "deploy/test"
  git -C "$FIX" mv src/m/Old.sol src/m/New.sol
  _sed_inplace 's/contract Old /contract New /' "$FIX/src/m/New.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m rename
  printf 'deploy/test {deployments/m.json:contractPath}\n' >"$FIX/.verify-audit-ignore"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/m/New.sol (cleared: bytecode-equivalent)"* ]]
}

# ----------------------------------------------------------------------------
# ARGUMENT RESOLUTION — patterns may match nothing, explicit names must resolve,
# and a revision need not be a tag
# ----------------------------------------------------------------------------

@test "an explicit name that does not resolve is an error, not a silent pass" {
  # A deliberately-named revision is a claim that it exists. Reporting success on a
  # typo tells the caller everything is fine having compared against nothing.
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "deploy/test"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/definitely-not-a-tag"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"deploy/definitely-not-a-tag"* ]]
}

@test "a pattern matching nothing is informational, not an error" {
  # The complement of the test above: a wildcard is a search, and finding nothing
  # is a legitimate answer.
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _commit_fixture >/dev/null
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy*"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tags match"* ]]
}

@test "a commit SHA is resolved and compared, not looked up as a tag" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  base=$(_commit_fixture)
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "$base"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGED (not ignored)"* ]]
  [[ "$output" == *"src/Foo.sol"* ]]
}

@test "a branch name is resolved and compared" {
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _commit_fixture >/dev/null
  git -C "$FIX" branch deploy-baseline
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy-baseline"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGED (not ignored)"* ]]
  [[ "$output" == *"src/Foo.sol"* ]]
}

@test "a name that is both a tag and a branch resolves as the tag, and says so" {
  # The tag is at the unchanged version and the branch at the changed one, so the
  # exit status alone distinguishes which was used: resolving the branch would
  # compare HEAD against itself and pass.
  _new_fixture
  cat >"$FIX/src/Foo.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Foo { function f() external pure returns (uint256) { return 1; } }
SOL
  _tag_fixture "both"
  _sed_inplace 's/return 1;/return 2;/' "$FIX/src/Foo.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m change
  git -C "$FIX" branch both 2>/dev/null
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "both"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/Foo.sol"* ]]
  [[ "$output" == *"is both a tag and a branch; using the tag"* ]]
}

# ----------------------------------------------------------------------------
# MIS-PAIRING — git pairs renames by textual similarity, and when it is wrong a
# deleted deployed contract vanishes from the report entirely
# ----------------------------------------------------------------------------

# A deployed contract deleted in the same commit that adds an unrelated one of similar
# shape. Git pairs them as a rename (measured: R068), so `--diff-filter=D` yields nothing
# and the deletion is absorbed. Leaves $BASE as the revision to audit against.
_mispair_fixture() {
  _new_fixture
  cat >"$FIX/src/Deployed.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Deployed {
    uint256 public constant DECIMALS = 18;
    uint256 public constant HEARTBEAT = 3600;
    function latestAnswer() external pure returns (uint256) { return 1234; }
    function description() external pure returns (string memory) { return "deployed"; }
}
SOL
  BASE=$(_commit_fixture)
  git -C "$FIX" rm -q src/Deployed.sol
  mkdir -p "$FIX/src" # git removes the directory when its last file goes
  cat >"$FIX/src/Unrelated.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Unrelated {
    uint256 public constant DECIMALS = 18;
    uint256 public constant HEARTBEAT = 7200;
    function latestAnswer() external pure returns (uint256) { return 9999; }
    function description() external pure returns (string memory) { return "unrelated"; }
}
SOL
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m swap
}

@test "a deletion git mis-paired as a rename is still named in the report" {
  # The whole point of the audit is noticing that a deployed contract went away. Reporting
  # only the new path lets the removal ship unseen.
  _mispair_fixture
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "$BASE"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/Deployed.sol"* ]]
}

@test "a pairing whose bytecode differs says it may be a mis-paired deletion" {
  # Bytecode cannot separate "this contract changed" from "a deletion was mis-paired with an
  # unrelated new file" - the old bytecode is absent from HEAD either way. So the report must
  # put both explanations in front of the reader rather than picking one.
  _mispair_fixture
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "$BASE"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/Deployed.sol"* && "$output" == *"src/Unrelated.sol"* ]]
  [[ "$output" == *"removed"* ]]
}

# A file whose text is mostly comments, so deleting the comments drops similarity below git's
# 50% rename threshold while the compiled bytecode is unchanged. This is the case git cannot
# pair and _locate_moved cannot either (it needs byte-identical content).
_unpairable_by_git_fixture() { # $1 = contract name at HEAD, $2 = destination path
  _new_fixture
  mkdir -p "$FIX/src/old"
  {
    echo "// SPDX-License-Identifier: MIT"
    echo "pragma solidity ^0.8.20;"
    for i in {1..40}; do echo "// explanatory prose line $i about the pricing model and its bounds"; done
    echo "contract Moved {"
    echo "    uint256 public constant K = 3;"
    echo "    function f(uint256 x) external pure returns (uint256) { return x + K; }"
    echo "}"
  } >"$FIX/src/old/Moved.sol"
  BASE=$(_commit_fixture)
  git -C "$FIX" rm -q src/old/Moved.sol
  mkdir -p "$FIX/${2%/*}"
  {
    echo "// SPDX-License-Identifier: MIT"
    echo "pragma solidity ^0.8.20;"
    echo "contract $1 {"
    echo "    uint256 public constant K = 3;"
    echo "    function f(uint256 x) external pure returns (uint256) { return x + K; }"
    echo "}"
  } >"$FIX/$2"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m move
}

@test "a move git could not pair is paired by bytecode, naming both paths" {
  _unpairable_by_git_fixture "Renamed" "src/new/Renamed.sol"
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "$BASE"
  echo "status=$status"
  echo "output=$output"
  [[ "$output" == *"src/old/Moved.sol"* ]]
  [[ "$output" == *"src/new/Renamed.sol"* ]]
  [ "$status" -eq 0 ]
}

@test "two HEAD files sharing a signature is an ambiguity, never a silent pick" {
  # A contract's name does not reach its creation bytecode, so two files with the same body
  # and different names have identical signatures. Choosing one would be a guess.
  _new_fixture
  mkdir -p "$FIX/src/old"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Moved {\n  uint256 public constant K = 3;\n  function f(uint256 x) external pure returns (uint256){ return x + K; }\n}\n' >"$FIX/src/old/Moved.sol"
  BASE=$(_commit_fixture)
  git -C "$FIX" rm -q src/old/Moved.sol
  mkdir -p "$FIX/src/new"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Twin1 {\n  uint256 public constant K = 3;\n  function f(uint256 x) external pure returns (uint256){ return x + K; }\n}\n' >"$FIX/src/new/Twin1.sol"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Twin2 {\n  uint256 public constant K = 3;\n  function f(uint256 x) external pure returns (uint256){ return x + K; }\n}\n' >"$FIX/src/new/Twin2.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m twins
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "$BASE"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/old/Moved.sol"* ]]
  [[ "$output" == *"more than one"* ]]
}

@test "a signature that identifies nothing never pairs" {
  # A file of abstract contracts compiles to an empty creation object, which every other such
  # file shares. Pairing on it would match unrelated files to each other.
  _new_fixture
  mkdir -p "$FIX/src/old"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\nabstract contract Gone {\n  function f() external pure virtual returns (uint256);\n}\n' >"$FIX/src/old/Gone.sol"
  BASE=$(_commit_fixture)
  git -C "$FIX" rm -q src/old/Gone.sol
  mkdir -p "$FIX/src/new"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\nabstract contract Fresh {\n  function g() external pure virtual returns (uint256);\n}\n' >"$FIX/src/new/Fresh.sol"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m abstracts
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "$BASE"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/old/Gone.sol"* ]]
  [[ "$output" != *"src/new/Fresh.sol is the same"* ]]
}

# ── the dependency-version check, which runs before any tag is looked at ──────────────────────────

# A repository whose dependency stages a shared dependency at a different commit than it does - what
# `dependency-conflicts.py` reports. The owner is read positionally from the URL, so a directory name
# stands in for a GitHub organisation: everything lives under one `acme`, which is what makes the
# dependency count as ours. Taking a submodule named bao-base is what makes it share our toolchain.
# Leaves $FIX as the host repository.
_new_conflicted_fixture() {
  ORG="$(mktemp -d)/acme"
  mkdir -p "$ORG"
  for name in shared bao-base; do
    git init -q "$ORG/$name"
    git -C "$ORG/$name" config user.email t@t
    git -C "$ORG/$name" config user.name test
    printf 'one\n' >"$ORG/$name/a.txt"
    git -C "$ORG/$name" add -A && git -C "$ORG/$name" commit -q -m one
  done
  printf 'two\n' >"$ORG/shared/a.txt"
  git -C "$ORG/shared" add -A && git -C "$ORG/shared" commit -q -m two

  git init -q "$ORG/dep"
  git -C "$ORG/dep" config user.email t@t
  git -C "$ORG/dep" config user.name test
  git -C "$ORG/dep" -c protocol.file.allow=always submodule add -q "$ORG/bao-base" lib/bao-base
  git -C "$ORG/dep" -c protocol.file.allow=always submodule add -q "$ORG/shared" lib/shared
  git -C "$ORG/dep/lib/shared" checkout -q HEAD~1 # the dependency stays on the older commit
  git -C "$ORG/dep" add lib/shared
  git -C "$ORG/dep" commit -q -m deps

  FIX="$ORG/host"
  git init -q "$FIX"
  git -C "$FIX" config user.email t@t
  git -C "$FIX" config user.name test
  git -C "$FIX" remote add origin "$ORG/host.git" # never fetched from; it is where the owner is read
  printf '[profile.default]\nsrc = "src"\nout = "out"\n' >"$FIX/foundry.toml"
  mkdir -p "$FIX/src"
  git -C "$FIX" add -A && git -C "$FIX" commit -q -m init
  git -C "$FIX" -c protocol.file.allow=always submodule add -q "$ORG/dep" lib/dep
  git -C "$FIX" -c protocol.file.allow=always submodule add -q "$ORG/shared" lib/shared
  git -C "$FIX" commit -q -m deps
}

@test "a dependency-version disagreement stops the run before anything is compiled" {
  # It reported both at first, so one invocation would name everything wrong. In use that spends
  # minutes compiling to produce a verdict nobody may act on, printed under a qualification a screen
  # further up: "no changes under src/" reads as a pass however it was qualified.
  _new_conflicted_fixture
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/test"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared"* ]] # the disagreement is named
  [[ "$output" != *"=== deploy/test ==="* ]] # and nothing past it was attempted
}

@test "agreement is stated once, and the tag comparison then runs" {
  # The mirror: the check passing must not become a way for the run to end early, and it says so in
  # one INFO line rather than a block, so a clean run is not made longer by it.
  _new_conflicted_fixture
  git -C "$FIX/lib/shared" checkout -q HEAD~1 # both now stage the same commit
  git -C "$FIX" add lib/shared
  cd "$FIX"
  run "$BAO_BASE_RUN" verify-audit "deploy/definitely-not-a-tag"
  echo "status=$status"
  echo "output=$output"
  [[ "$output" == *"staged at the same commit"* ]]
  [[ "$output" == *"deploy/definitely-not-a-tag"* ]] # it reached the tag it could not resolve
}
