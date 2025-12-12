# BaoFactory Integration Proposal

## Current State

bao-factory exposes:

- `src/BaoFactory.sol` - The UUPS upgradeable factory contract
- `src/BaoFactoryLib.sol` - Address prediction library
- `src/IBaoFactory.sol` - Interface
- `generated/BaoFactoryBytecode.sol` - Captured creation code with stable addresses

bao-base needs:

- To import BaoFactory, BaoFactoryLib, IBaoFactory for deployment infrastructure
- To deploy a BaoFactory at a predictable address for testing on fresh EVMs
- Captured bytecode for production deployments

## Problem 1: Remapping Confusion

Current remapping in bao-base:

```
"@bao-factory/=lib/bao-factory/generated/"
```

This only covers `generated/`, but `BaoFactory.sol` and `BaoFactoryLib.sol` live in `src/`.

### Proposed Solution: Single Remapping to src/

```
"@bao-factory/=lib/bao-factory/src/"
```

Then move or re-export `BaoFactoryBytecode.sol` from `src/` instead of `generated/`.

**Option A: Symlink or copy**

- Have `src/BaoFactoryBytecode.sol` that imports and re-exports from `generated/`

**Option B: Move generated content into src**

- The `--extract` script writes directly to `src/BaoFactoryBytecode.sol`
- Simpler, single source of truth

**Recommendation: Option B** - The generated file is still auto-generated, just lives in `src/`.

## Problem 2: Duplicate IBaoFactory.sol

Currently `IBaoFactory.sol` exists in both `src/` and `generated/`.

### Proposed Solution

Delete `generated/IBaoFactory.sol`. The interface rarely changes and doesn't need to be "extracted" - it's source code, not bytecode.

## Problem 3: Testing Infrastructure

To test on a fresh EVM (not forked), we need to:

1. Have Nick's Factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`
2. Deploy BaoFactory via Nick's Factory to get predictable addresses
3. Set test harness as operator (requires pranking as owner)

Currently, `DeploymentInfrastructure._ensureBaoFactoryCurrentBuild()` handles this, but it lives in bao-base and imports from bao-factory. The circular dependency is:

- bao-base tests need BaoFactory deployed
- Deployment logic lives in bao-base
- bao-factory doesn't have test helpers

### Proposed Solution: Add Test Helper to BaoFactoryBytecode.sol

Add a library function that deploys BaoFactory using `vm.etch` and returns the proxy address:

```solidity
// In lib/bao-factory/src/BaoFactoryBytecode.sol

import {Vm} from "forge-std/Vm.sol";
import {BaoFactoryLib} from "./BaoFactoryLib.sol";

library BaoFactoryBytecode {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Nick's Factory bytecode (for deployment to fresh chains)
    bytes internal constant NICKS_FACTORY_BYTECODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    bytes internal constant CREATION_CODE = hex"...";  // existing
    bytes32 internal constant CREATION_CODE_HASH = ...; // existing

    // Production constants
    string internal constant PRODUCTION_SALT = "Bao.BaoFactory.v1";
    address internal constant PRODUCTION_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    // Predicted addresses for production salt
    address internal constant PREDICTED_IMPLEMENTATION = ...;
    address internal constant PREDICTED_PROXY = ...;

    /// @notice Deploy BaoFactory for testing on fresh EVM
    /// @dev Uses vm.etch for Nick's Factory if needed, then deploys via CREATE2
    /// @return proxy The BaoFactory proxy address
    function deployForTesting() internal returns (address proxy) {
        // Ensure Nick's Factory exists
        if (BaoFactoryLib.NICKS_FACTORY.code.length == 0) {
            vm.etch(BaoFactoryLib.NICKS_FACTORY, NICKS_FACTORY_BYTECODE);
        }

        // Predict addresses
        address implementation = BaoFactoryLib.predictImplementation(
            PRODUCTION_SALT,
            CREATION_CODE_HASH
        );
        proxy = BaoFactoryLib.predictProxy(implementation);

        // If already deployed, return early
        if (proxy.code.length > 0) {
            return proxy;
        }

        // Deploy via Nick's Factory
        bytes32 salt = keccak256(bytes(PRODUCTION_SALT));
        bytes memory creationCode = CREATION_CODE;

        assembly {
            let codeLength := mload(creationCode)
            mstore(creationCode, salt)
            if iszero(call(gas(), 0x4e59b44847b379578588920cA78FbF26c0B4956C, 0, creationCode, add(codeLength, 0x20), 0x00, 0x20)) {
                revert(0, 0)
            }
            mstore(creationCode, codeLength)
        }

        require(proxy.code.length > 0, "BaoFactory deployment failed");
    }

    /// @notice Set operator on BaoFactory (pranks as owner)
    /// @param proxy The BaoFactory proxy address
    /// @param operator The operator address to authorize
    /// @param duration How long the operator authorization lasts
    function setOperatorForTesting(address proxy, address operator, uint256 duration) internal {
        vm.prank(PRODUCTION_OWNER);
        IBaoFactory(proxy).setOperator(operator, duration);
    }
}
```

### Alternative: Use vm.etch Directly for Both

An even simpler approach - etch the entire proxy at the predicted address:

```solidity
/// @notice Etch BaoFactory at predicted address for testing
/// @dev Bypasses actual deployment, just places code at expected addresses
/// @return proxy The BaoFactory proxy address
function etchForTesting() internal returns (address proxy) {
  // Get predicted addresses
  address implementation = PREDICTED_IMPLEMENTATION;
  proxy = PREDICTED_PROXY;

  // Etch implementation
  // We need the runtime code, not creation code
  // This requires capturing runtime code separately OR deploying once and capturing

  // ... this approach is more complex because we need runtime bytecode
}
```

**Problem with vm.etch approach**: We have creation code but need runtime code. Creation code includes constructor logic that we'd skip.

**Recommendation**: Use the Nick's Factory deployment approach. It's a real deployment that exercises the actual code paths.

## Proposed File Structure in bao-factory

```
lib/bao-factory/
├── src/
│   ├── BaoFactory.sol           # Main contract
│   ├── BaoFactoryLib.sol        # Address prediction
│   ├── BaoFactoryBytecode.sol   # Captured bytecode + test helpers (moved from generated/)
│   └── IBaoFactory.sol          # Interface
├── generated/
│   └── (empty or removed)
├── script/
│   └── bao-factory              # Extract script (outputs to src/)
└── test/
    └── ...
```

## Proposed Remappings in bao-base

```toml
remappings = [
  # ... existing ...
  "@bao-factory/=lib/bao-factory/src/",
]
```

Remove the `@bao/factory/` remapping entirely - everything goes through `@bao-factory/`.

## Import Changes Required in bao-base

| File                         | Old Import                                      | New Import                            |
| ---------------------------- | ----------------------------------------------- | ------------------------------------- |
| Multiple                     | `@bao/factory/BaoFactory.sol`                   | `@bao-factory/BaoFactory.sol`         |
| Multiple                     | `@bao/factory/BaoFactoryLib.sol`                | `@bao-factory/BaoFactoryLib.sol`      |
| DeploymentInfrastructure.sol | Already correct                                 | Already correct                       |
| DeploymentVariant.sol        | `@bao-script/deployment/BaoFactoryBytecode.sol` | Removed (variant mixin deleted)       |

## Migration Steps

1. **In bao-factory:**

   - Move `generated/BaoFactoryBytecode.sol` to `src/BaoFactoryBytecode.sol`
   - Update `script/bao-factory --extract` to output to `src/`
   - Delete `generated/IBaoFactory.sol`
   - Add `deployForTesting()` and `setOperatorForTesting()` to `BaoFactoryBytecode.sol`
   - Add Nick's Factory bytecode constant to `BaoFactoryBytecode.sol`
   - Rename constants: `CREATION_CODE` → `PRODUCTION_CREATION_CODE` for clarity (or keep as-is since there's only one variant now)

2. **In bao-base:**
    - Update `foundry.toml` remapping: `"@bao-factory/=lib/bao-factory/src/"`
    - Fix imports: `@bao/factory/*` → `@bao-factory/*`
    - Delete `DeploymentVariant.sol`; rely on `DeploymentJsonScript`'s default `_ensureBaoFactory()`
   - Fix imports: `@bao-script/deployment/BaoFactoryBytecode.sol` → `@bao-factory/BaoFactoryBytecode.sol`
   - Simplify `DeploymentInfrastructure.sol` to use `BaoFactoryBytecode.deployForTesting()`
   - Delete `src/factory/` directory entirely
   - Remove Nick's Factory bytecode from `DeploymentInfrastructure.sol` (moved to bao-factory)

## Questions for Discussion

1. **Naming**: Should bytecode constants be prefixed with `PRODUCTION_`? There's only one variant now, but the prefix is self-documenting.

2. **forge-std dependency**: Adding `deployForTesting()` creates a forge-std dependency in bao-factory. Is that acceptable? Alternatives:

   - Make it a separate file `BaoFactoryTestHelpers.sol` that's clearly test-only
   - Keep test helpers in bao-base (status quo, but messier)

3. **Salt choice**: The current generated bytecode uses salt "Bao.BaoFactory.harbor". Should this be "Bao.BaoFactory.v1" (production) or keep separate testing/production salts?

4. **Runtime code capture**: Should we also capture runtime code for potential `vm.etch` usage? This would enable faster test setup but adds complexity to the extract script.
