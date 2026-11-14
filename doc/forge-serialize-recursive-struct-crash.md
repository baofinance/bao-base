# forge aborts when a JSON cheatcode meets a struct that holds itself through an array

**Status:** reported to foundry as [foundry-rs/foundry#18464](https://github.com/foundry-rs/foundry/issues/18464)
on 2026-11-14.

## In bao-base

- **What happens.** `yarn test` aborts with `thread 'solar-0' has overflowed its stack`, prints no summary, and
  exits 1, whenever a test calls a `vm.serialize*` cheatcode (`serializeUint` and `serializeString` were run). By
  foundry's source, `vm.parseJson`, `vm.parseJsonType*` and `vm.serializeJsonType` reach the same code; those were
  not run.
- **Why bao-base meets it.** The storage-layout fixtures in `test/fixtures/BaoUpgradeFixtures.sol`
  (`SelfRootPred`, `SelfRootSucc`) declare `struct Node { Node[] children; ... }`, which is valid Solidity. The
  cheatcodes above make forge resolve every struct in the build, and its resolver never ends on such a struct.
- **When.** In bao-base it was seen on runs whose build was cached ("No files changed, compilation skipped"). Runs
  that compiled a few changed files passed. In a fresh project, every run aborts.
- **Workaround.** No bao-base code calls any of these cheatcodes: `JsonSerializer` builds its JSON as strings, and
  `stdJson`'s `read*` functions use cheatcodes that do not reach the resolver. `JsonFileLibTest` writes a literal
  JSON string, and says why.
- **Found** 2026-11-13, on forge 1.9.0, while adding `JsonFileLib`.

## The issue, as raised

**Title:** `forge test` aborts with a stack overflow when a `vm.serialize*` cheatcode runs in a project holding a
struct that contains itself through an array

**Component:** Forge

**Up to date:** Foundry 1.9.0 is the latest stable release. Nightly was not tested, but
`crates/cheatcodes/src/inspector/analysis.rs` is identical at `v1.9.0` and on `master` as of 2026-11-14.

**Foundry version:** `forge Version: 1.9.0`, `Commit SHA: 6056c5845d34205a83cf7108042adb137325c9df`

**Foundryup version:** `foundryup 2.0.0 (ca05497 2026-10-24T16:30:01.184081515Z)`

**Command:** `forge test`

**Operating system:** Linux (x86_64)

### Describe the bug

`forge test` aborts the whole process with a stack overflow when a test calls `vm.serializeUint` (or any
`vm.serialize*` cheatcode), and the project contains a struct that holds itself through an array. Such a struct is
valid Solidity. No test result or summary is printed, and the exit status is 134.

**Reproduction**, from a fresh project (forge-std 1.17.0, solc 0.8.35):

```sh
forge init repro && cd repro
```

`src/Recursive.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract Recursive {
    struct Node {
        Node[] children;
    }
}
```

`test/Serialize.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

contract SerializeTest is Test {
    function test_serializeUint() public {
        vm.serializeUint("object", "value", 1);
    }
}
```

```sh
forge test
```

**Output** (the template's Counter tests pass first):

```text
[PASS] testFuzz_SetNumber(uint256) (runs: 256, μ: 50112, ~: 52529)
[PASS] test_Increment() (gas: 51847)

thread 'solar-0' (…) has overflowed its stack
fatal runtime error: stack overflow, aborting
Aborted (core dumped)
```

**Expected:** the test passes, as it does when the struct is removed.

**What makes the difference**, each tried on its own:

| change | result |
|---|---|
| no `Recursive` struct, or a struct that does not contain itself | passes |
| `mapping(uint256 => Node) children;` instead of `Node[] children;` | passes |
| `vm.serializeString` instead of `vm.serializeUint` | aborts |
| `vm.parseJsonUint` instead, or no cheatcode | passes |
| two structs holding arrays of each other (`A { B[] bs; }`, `B { A[] as_; }`) | aborts |

**Backtrace** of the crashing thread, from gdb (59,331 frames, the middle elided):

```text
Thread 91 "solar-1" received signal SIGSEGV, Segmentation fault.
#0  do_rallocx ()
…
#6  foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::get_fully_qualified_name ()
#7  foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::resolve_struct_definition ()
#8  foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::ty_to_string ()
#9  foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::ty_to_string ()
#10 foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::resolve_struct_definition ()
#11 foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::ty_to_string ()
…
#59323 foundry_cheatcodes::inspector::analysis::StructDefinitionResolver::resolve_struct_definition ()
#59324 rayon_core::job::StackJob<…ThreadPool::install<solar_sema::compil…
#59326 rayon_core::registry::ThreadBuilder::run ()
#59327 …solar_interface::session::Session::thread_pool…
```

**Cause**, read from the source
([`analysis.rs` at v1.9.0](https://github.com/foundry-rs/foundry/blob/v1.9.0/crates/cheatcodes/src/inspector/analysis.rs#L100-L156)).
Every `vm.serialize*` cheatcode goes through `serialize_json` in `json.rs`, which calls `state.struct_defs()`. On
first use, that resolves every struct in the build with `StructDefinitionResolver`. `resolve_struct_definition`
returns early only for a struct already in `struct_defs`, but it inserts the struct only after resolving all its
fields:

```rust
let qualified_name = self.get_fully_qualified_name(id);
if self.struct_defs.contains_key(&qualified_name) {
    return Ok(());
}
// ... for each field: self.ty_to_string(...)
self.struct_defs.insert(qualified_name, fields);
```

For `Node { Node[] children; }`, `ty_to_string` meets `DynArray(Struct(Node))`, recurses into the element, and
calls `resolve_struct_definition(Node)` again, before `Node` is inserted, without end. A mapping field falls
through to `_ => return None` in `ty_to_string`, so the mapping form does not recurse. Solidity does not allow a
struct to hold itself through a fixed-size array, so a dynamic array is the one form that recurses, directly or
through other structs.

**A possible fix (untested):** remember the structs being resolved, and let a reference back to one of them resolve
to its name:

```rust
struct StructDefinitionResolver<'gcx> {
    gcx: Gcx<'gcx>,
    struct_defs: TypeDefMap,
    resolving: HashSet<hir::StructId>,
}

fn resolve_struct_definition(&mut self, id: hir::StructId) -> Result<(), AnalysisError> {
    let qualified_name = self.get_fully_qualified_name(id);
    if self.struct_defs.contains_key(&qualified_name) || !self.resolving.insert(id) {
        return Ok(());
    }
    // ... resolve the fields, as now ...
    self.resolving.remove(&id);
    // ... insert, as now ...
}
```

`ty_to_string` then gives the recursive field the type `Recursive.Node[]`.

**Seen in a larger project:** there, runs that compiled a few changed files passed, and runs whose build was
cached aborted. It looked as if the analysis covers only the sources the run's compiler session holds; this was not
checked further.
