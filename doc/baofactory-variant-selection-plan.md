# BaoFactory Variant Selection Plan

## Problem Statement

We need to support multiple BaoFactory variants with different hardcoded owners, selectable at runtime via environment variable. This enables:

1. **Testing flexibility** - Use different owners for different test scenarios
2. **Testnet validation** - Test captured bytecode deployment before production
3. **Accidental collision prevention** - Salt derived from variant name ensures production addresses can't be accidentally occupied

## Design Principles

1. **Script-generated variants** - The bytecode extraction script generates variant Solidity files dynamically, compiles them, and extracts bytecode. This minimizes human effort when adding new variants.

2. **Minimal manual code** - `BaoFactory.sol` contains only `BaoFactoryOwnerless` (abstract base) + production variant. All other variants are generated.

3. **Verification** - Script verifies production bytecode matches existing captured bytecode to catch accidental breaking changes.

## Variant Configuration

Variants are defined as `(name, owner_address)` pairs in the script:

| Name           | Contract                 | Owner                                        | Salt                                         |
| -------------- | ------------------------ | -------------------------------------------- | -------------------------------------------- |
| (empty)        | `BaoFactory`             | `0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2` | `keccak256("Bao.BaoFactory.v1")`             |
| `Testing`      | `BaoFactoryTesting`      | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `keccak256("Bao.BaoFactoryTesting.v1")`      |
| `RootMinus0x1` | `BaoFactoryRootMinus0x1` | `0x0DC59a2caD3e1fa5D6b8a0F7c1481FcEDFa0bBCA` | `keccak256("Bao.BaoFactoryRootMinus0x1.v1")` |

### Address Derivation

```
Implementation = CREATE2(Nick's Factory, keccak256("Bao.BaoFactory{Name}.v1"), keccak256(creationCode))
                         ↓                           ↓                              ↓
                      constant                 derived from name              includes owner
                                                                              (in bytecode)

Proxy = CREATE(implementation, nonce=1)
              ↓
        derived from above
```

The owner affects the address **once**: it's embedded in the bytecode, which changes `creationCodeHash`, which changes the implementation address, which changes the proxy address.

## Two Distinct Modes

### 1. DeploymentTesting (`.t.sol` tests)

- **Always uses current build** (`type(BaoFactory).creationCode`)
- **Uses production variant** (`BaoFactory` with production owner)
- Pranks the hardcoded owner to set operators
- **No environment variable override** for variant selection

### 2. Production/Script Mode (DeploymentJsonScript, etc.)

- **Environment variable `BAO_FACTORY_VARIANT`** selects variant
- **Must use exact string `"Bao.BaoFactory.v1"`** for production
- Other variants match by name suffix: `Testing` → `BaoFactoryTesting`
- Uses captured bytecode from `BaoFactoryBytecode.sol`

### Environment Variable: `BAO_FACTORY_VARIANT`

| Value               | Contract                 | Salt                                         | Bytecode |
| ------------------- | ------------------------ | -------------------------------------------- | -------- |
| `Bao.BaoFactory.v1` | `BaoFactory`             | `keccak256("Bao.BaoFactory.v1")`             | Captured |
| `Testing`           | `BaoFactoryTesting`      | `keccak256("Bao.BaoFactoryTesting.v1")`      | Captured |
| `RootMinus0x1`      | `BaoFactoryRootMinus0x1` | `keccak256("Bao.BaoFactoryRootMinus0x1.v1")` | Captured |
| (not set)           | `BaoFactory`             | `keccak256("Bao.BaoFactory.v1")`             | Captured |

**Production requires exact string** `"Bao.BaoFactory.v1"` - this prevents accidental production deployment with wrong variant.

## File Structure

```
script/deployment/
├── BaoFactory.sol                    # BaoFactoryOwnerless (abstract base) + production variant
├── BaoFactoryBytecode.sol            # Auto-generated: bytecode constants for all variants
├── BaoFactoryVariants.sol            # NEW: Variant selection logic
├── DeploymentInfrastructure.sol      # Uses BaoFactoryVariants
└── ...

script/
└── extract-bytecode-baofactory       # Generates variants, compiles, extracts bytecode

out/_factory-variants/                # Temporary: compiled generated variants
```

## Script-Generated Variants Process

The `extract-bytecode-baofactory` script:

1. **Reads variant configuration** from embedded list:

   ```bash
   VARIANTS=(
       ":0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2"           # Production
       "Testing:0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"    # Anvil
       "RootMinus0x1:0x0DC59a2caD3e1fa5D6b8a0F7c1481FcEDFa0bBCA" # Personal
   )
   ```

2. **For production variant** (empty name): extracts bytecode directly from `BaoFactory`

3. **For other variants**: generates temporary Solidity file:

   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.26;
   import { BaoFactoryOwnerless } from "script/deployment/BaoFactory.sol";

   contract BaoFactoryTesting is BaoFactoryOwnerless {
     address public constant override owner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
   }
   ```

4. **Compiles** generated files using project remappings to `out/_factory-variants/`

5. **Extracts bytecode** from compilation artifacts

6. **Verifies production bytecode** matches existing captured bytecode (if exists) - catches accidental breaking changes

7. **Generates `BaoFactoryBytecode.sol`** with all variant bytecode constants

### Adding New Variants

Just add to the `VARIANTS` array in the script and run `yarn extract-bytecode-baofactory`:

```bash
# Add new variant
VARIANTS=(
    ...existing...
    "MyNewVariant:0x1234567890123456789012345678901234567890"
)
```

That's it. No manual Solidity code changes required.

## Implementation Phases

### Phase 1: Update BaoFactory.sol

| ID  | Task                                                                                  | Status  |
| --- | ------------------------------------------------------------------------------------- | ------- |
| 1.1 | Remove manually-defined test variants (`BaoFactoryTesting`, `BaoFactoryRootMinus0x1`) | ✅ Done |
| 1.2 | Remove owner abstract contracts (`OwnerAnvil`, etc.)                                  | ✅ Done |
| 1.3 | Keep only `BaoFactoryOwnerless` and production `BaoFactory`                           | ✅ Done |
| 1.4 | Add `IBaoFactory` interface for events/errors                                         | ✅ Done |
| 1.5 | Add documentation explaining script-generated variants                                | ✅ Done |

### Phase 2: Update Bytecode Extraction Script

Update `extract-bytecode-baofactory` to generate variants dynamically.

| ID  | Task                                                          | Status  |
| --- | ------------------------------------------------------------- | ------- |
| 2.1 | Add `VARIANTS` config array to script                         | ✅ Done |
| 2.2 | Generate temporary Solidity files for non-production variants | ✅ Done |
| 2.3 | Compile to `out/_factory-variants/` using project remappings  | ✅ Done |
| 2.4 | Verify production bytecode matches existing (if present)      | ✅ Done |
| 2.5 | Generate `BaoFactoryBytecode.sol` with all variants           | ✅ Done |
| 2.6 | Clean up temporary files after generation                     | ✅ Done |

**Generated `BaoFactoryBytecode.sol` structure:**

```solidity
library BaoFactoryBytecode {
    // Production variant (BaoFactory)
    bytes internal constant PRODUCTION_CREATION_CODE = hex"...";
    bytes32 internal constant PRODUCTION_CREATION_CODE_HASH = 0x...;

    // Testing variant (BaoFactoryTesting)
    bytes internal constant TESTING_CREATION_CODE = hex"...";
    bytes32 internal constant TESTING_CREATION_CODE_HASH = 0x...;

    // RootMinus0x1 variant (BaoFactoryRootMinus0x1)
    bytes internal constant ROOTMINUS0X1_CREATION_CODE = hex"...";
    bytes32 internal constant ROOTMINUS0X1_CREATION_CODE_HASH = 0x...;
}
```

### Phase 3: Three Deployment Modes

Instead of a separate `BaoFactoryVariants.sol`, variant selection is integrated into the deployment infrastructure with three distinct modes:

| ID  | Task                                                              | Status  |
| --- | ----------------------------------------------------------------- | ------- |
| 3.1 | `_ensureBaoFactoryCurrentBuild()` - uses current build            | ✅ Done |
| 3.2 | `_ensureBaoFactoryProduction()` - uses captured bytecode          | ✅ Done |
| 3.3 | `_ensureBaoFactoryWithConfig()` - core logic with explicit config | ✅ Done |
| 3.4 | `DeploymentTesting._ensureBaoFactory()` - calls CurrentBuild      | ✅ Done |
| 3.5 | `Deployment._ensureBaoFactory()` - calls Production               | ✅ Done |
| 3.6 | `DeploymentJsonScript._ensureBaoFactory()` - calls Production     | ✅ Done |

**Mode separation:**

- `DeploymentTesting`: Uses current build, no vm dependency (pranks owner)
- `Deployment` (production): Uses captured bytecode, no vm dependency
- `DeploymentJsonScript`: Uses production bytecode by default for scripts

### Phase 4: Update DeploymentInfrastructure

| ID  | Task                                                              | Status  |
| --- | ----------------------------------------------------------------- | ------- |
| 4.1 | Refactor to three mode functions                                  | ✅ Done |
| 4.2 | `predictBaoFactoryAddress()` uses production config               | ✅ Done |
| 4.3 | Salt derived from variant: `keccak256("Bao.BaoFactory{Name}.v1")` | ✅ Done |

### Phase 5: Tests

| ID  | Task                                              | Status  |
| --- | ------------------------------------------------- | ------- |
| 5.1 | Test production variant deployment                | ✅ Done |
| 5.2 | Test current build deployment                     | ✅ Done |
| 5.3 | Test salt derivation matches expected             | ✅ Done |
| 5.4 | Test address prediction matches actual deployment | ✅ Done |
| 5.5 | Update tests to use IBaoFactory for events/errors | ✅ Done |

### Phase 6: Documentation

| ID  | Task                                | Status      |
| --- | ----------------------------------- | ----------- |
| 6.1 | Update deployment architecture doc  | Not Started |
| 6.2 | Document environment variable usage | Not Started |
| 6.3 | Document how to add new variants    | Not Started |

## Risks & Mitigations

| Risk                                      | Mitigation                                             |
| ----------------------------------------- | ------------------------------------------------------ |
| Deploying wrong variant to production     | Production requires exact string `"Bao.BaoFactory.v1"` |
| Captured bytecode becomes stale           | Script verifies production bytecode matches existing   |
| Environment variable not set              | Default to production                                  |
| Confusing which variant is active         | Log variant name during deployment                     |
| Breaking production bytecode accidentally | Verification step in script fails if bytecode changes  |
