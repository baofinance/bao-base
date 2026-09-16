> **Status.** Filed as https://github.com/foundry-rs/foundry/issues/16901 on 2026-09-16; open. The
> text below is the body as filed.

### Component

Forge

### Have you ensured that all of these are up to date?

- [x] Foundry
- [x] Foundryup

### What version of Foundry are you on?

forge Version: 1.8.3, Commit SHA: cae51ad458f6abb64852b7709eb784352429825d

### What version of Foundryup are you on?

1.8.6

### What command(s) is the bug in?

forge test

### Operating System

Linux

### Describe the bug

Follow-up to #16682, which #16686 fixed for contracts in the `src` directory.

When a test does `new Contract(...)` for a contract **outside the `src` directory**, such as a
dependency under `lib/`, a body-only change to that contract is still not picked up. The test file is
not recompiled and the old creation code runs. It does not matter whether the import is remapped or
relative, or whether the directory is listed in `libs`.

This is the normal layout for a project that tests against another project's contracts through a
git submodule. The test passes against source it cannot pass against, and nothing warns.

## Minimal reproduction

```bash
mkdir -p repro/src repro/test repro/lib/dep/src && cd repro

cat > foundry.toml <<'EOF'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
remappings = ["@dep/=lib/dep/src/"]
EOF

cat > lib/dep/src/Impl.sol <<'EOF'
pragma solidity ^0.8.20;
contract Impl { function v() external pure returns (uint256) { return 111; } }
EOF

cat > test/Impl.t.sol <<'EOF'
pragma solidity ^0.8.20;
import {Impl} from "@dep/Impl.sol";
contract Impl_Test {
    function test_v() public { require(new Impl().v() == 111, "v() != 111"); }
}
EOF

forge test                                          # [PASS] test_v() (gas: 124390)
sed -i 's/return 111;/return 222;/' lib/dep/src/Impl.sol
forge test                                          # Compiling 1 files
                                                    # [PASS] test_v() (gas: 124390)  <-- should FAIL
```

`forge test --no-dynamic-test-linking` or `forge test --force` on the second run correctly reports
`[FAIL: v() != 111]`.

## Which layouts are affected

Measured on 1.8.3 with the reproduction above, changing only where `Impl.sol` lives and how the test
imports it:

| contract location | import | `libs` | first run gas | body change |
|---|---|---|---|---|
| `src/` | `@p/Impl.sol` (remapped) | `["lib"]` | 4233 | seen (fixed by #16686) |
| `src/` | `../src/Impl.sol` | `["lib"]` | 4233 | seen |
| `lib/dep/src/` | `@dep/Impl.sol` (remapped) | `["lib"]` | 124390 | **lost** |
| `lib/dep/src/` | `../lib/dep/src/Impl.sol` | `["lib"]` | 124390 | **lost** |
| `lib/dep/src/` | `@dep/Impl.sol` (remapped) | `[]` | 124390 | **lost** |
| `dep/src/` | `@dep/Impl.sol` (remapped) | `[]` | 124390 | **lost** |
| `dep/src/` | `../dep/src/Impl.sol` | `[]` | 124390 | **lost** |

The gas shows the creation code is still inlined in every lost case: 124390 is a real `CREATE`, while
4233 is the dynamically linked deploy. So the test really does depend on the contract's bytecode, yet
it is not recompiled.

## Cause

The dynamic linking preprocessor and the build cache define "source file" differently.

The preprocessor rewrites `new` only for contracts in the configured `src` directory.
`crates/common/src/preprocessor/deps.rs` at v1.8.3:

```rust
if !is_path_in_dir(path, self.src_dir, self.root_dir) {
    let path = path.display();
    trace!("ignore dependency {path}");
    return;
}
```

The cache counts **any file that is not a test or script** as a source file. That includes `lib/`.
For those files it applies the interface-hash shortcut: a test importing a changed source file whose
interface is unchanged is not marked dirty. `foundry-compilers`, `crates/compilers/src/cache.rs` on
`main` (18b5178625):

```rust
} else if !is_src
    && self.dirty_sources.contains(import)
    && (!self.is_source_file(import)
        || self.is_dirty(import, true)
        || self.cache.mocks.contains(file))
```

with `ProjectPaths::is_source_file` being `!self.is_test_or_script(path)`.

So for `lib/dep/src/Impl.sol` the preprocessor leaves the `new` inlined, while the cache assumes it
was rewritten and skips the test file. #16686 made the preprocessor recognise remapped `src`
contracts, but a contract outside `src` still takes the `ignore dependency` return. Nothing records
it for cache invalidation there, unlike the conservative fallback #16686 added.

(forge 1.8.3 locks `foundry-compilers` 0.21.0. The code quoted above is from `main`; the measured
behaviour agrees with it.)

### Expected behaviour

A body-only change to any contract a test deploys with `new` is reflected in the next `forge test`,
wherever that contract lives.

The two definitions need to agree. Either the cache applies the interface-hash shortcut only to
contracts the preprocessor can rewrite, or the preprocessor treats an ignored bytecode dependency the
way #16686 treats a remapping it cannot rewrite safely: it keeps the test natively linked and records
it through the cache-invalidation mechanism.

### Actual behaviour

The test file is not recompiled, the previously inlined creation code runs, and the suite reports
passes and gas figures for source that no longer exists.

## Impact

Projects that test against contracts from a dependency, such as a shared base library consumed as a
submodule, get this on every test that deploys one of those contracts. We keep
`--no-dynamic-test-linking` in our test and gas runners for this reason. Our regression test for it
started failing on 1.8.3 because the `src` case is fixed, and moving the contract to `lib/` brought the
defect back.
