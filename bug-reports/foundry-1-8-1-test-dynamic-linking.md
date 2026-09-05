### Component

Forge

### Have you ensured that all of these are up to date?

- [x] Foundry
- [x] Foundryup

### What version of Foundry are you on?

forge Version: 1.8.1, Commit SHA: 982849d3140c01fd3b72905759581a132df7aa98

### What version of Foundryup are you on?

1.8.6

### What command(s) is the bug in?

forge test, forge build

### Operating System

Linux

### Describe the bug

When a test file imports a `src` contract **through a remapping**, dynamic test linking silently
declines to rewrite `new Contract(...)` — the creation code stays inlined in the test bytecode — but
the build cache still applies the shortcut that assumes the rewrite happened. The test file is
therefore never recompiled when only the contract's body changes, and the suite keeps running the
old bytecode.

The result is a test that passes against source it cannot possibly pass against, with gas figures
identical to the digit. Nothing warns.

Using a relative import for the same contract makes it behave correctly, so a project's import style
silently decides whether its tests are sound.

## Minimal reproduction

```bash
mkdir -p repro/src repro/test && cd repro

cat > foundry.toml <<'EOF'
[profile.default]
src = "src"
out = "out"
remappings = ["@p/=src/"]
EOF

cat > src/Impl.sol <<'EOF'
pragma solidity ^0.8.20;
contract Impl { function v() external pure returns (uint256) { return 111; } }
EOF

cat > test/Impl.t.sol <<'EOF'
pragma solidity ^0.8.20;
import {Impl} from "@p/Impl.sol";   // remapped -> bug.  "../src/Impl.sol" -> correct.
contract Impl_Test {
    function test_v() public { require(new Impl().v() == 111, "v() != 111"); }
}
EOF

forge test                                # [PASS] test_v() (gas: 124378)
sed -i 's/return 111;/return 222;/' src/Impl.sol
forge test                                # [PASS] test_v() (gas: 124378)  <-- should FAIL
```

Change the import to `../src/Impl.sol` and the second run correctly reports
`[FAIL: v() != 111] test_v() (gas: 4508)`.

The gas figures show the mechanism directly: **124378** with the remapped import (creation code
inlined, a real `CREATE`) versus **4233** with the relative one (dynamically linked, deployed at
runtime).

`forge build` shows the same thing — it reports `Compiling 1 files` (the contract only); the test
file's artifact keeps its old mtime.

`--no-dynamic-test-linking` makes the remapped project behave correctly, which is the workaround.

## Cause

`crates/common/src/preprocessor/deps.rs` gates the rewrite on the contract's source path being under
the `src` dir:

```rust
if !path.starts_with(self.src_dir) {
    trace!("ignore dependency {path}");
    return;
}
```

With `RUST_LOG=foundry_common::preprocessor=trace`, the two projects differ exactly there:

| import | path recorded for the contract | `starts_with(src_dir)` | outcome |
|---|---|---|---|
| `../src/Impl.sol` | `src/Impl.sol` | true | rewritten, deployed at runtime |
| `@p/Impl.sol` | `/abs/path/repro/src/Impl.sol` | **false** → `ignore dependency` | **left inlined** |

A remapped import yields an absolute path, which fails `starts_with` against the relative `src_dir`,
so the bytecode dependency is discarded and the `new` is left statically inlined.

Independently of that, the cache treats dependent test files as clean when only a contract's body
changes (its `interfaceReprHash` is unchanged) — correct *if* the rewrite happened. Here it did not,
so the two halves disagree and the stale artifact is used.

Either half alone would be safe. It is the combination that loses the change silently.

### Expected behaviour

A body-only change to a `src` contract is reflected in the next `forge test` run, regardless of
whether the test imports that contract relatively or through a remapping.

(Whichever way it is fixed — normalising the path before the `starts_with` check, or treating a
contract whose `new` could not be rewritten as a genuine dependency for cache invalidation — the
dirty-file logic and the rewrite need to agree, because a silent disagreement produces green tests
against code that cannot pass.)

### Actual behaviour

The test file is not recompiled, the previously inlined creation code runs, and the suite reports
passes and gas figures for source that no longer exists.

## Impact

Projects that use remappings for their own `src` tree — a common convention, and one some codebases
mandate so that the sources compile identically when consumed as a library — get this on **every**
test. In the repository where we found it, all 84 test artifacts had the creation code inlined, so
the rewrite never once succeeded while the cache shortcut fired on every run. Gas snapshots taken
since upgrading to 1.8 are frozen at their pre-change values.

Dynamic test linking became the default in v1.8.0 (#14718), so this reaches projects that never opted
in.
