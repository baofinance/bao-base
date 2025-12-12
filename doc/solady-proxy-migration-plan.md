# Migration Plan: OZ ERC1967Proxy → Solady LibClone + UUPSUpgradeable

## Problem Statement

The OpenZeppelin `ERC1967Proxy` includes a code-length check in `ERC1967Utils._setImplementation()` that reverts if the implementation address has no code. This blocks deterministic address patterns where the proxy address must be known before the implementation is deployed.

**Current issue in `BaoFactory.sol`:**

```solidity
constructor() {
  // This works because BaoFactory is deployed first, then proxy
  address proxy = address(new ERC1967Proxy(address(this), ""));
}
```

The current approach requires the implementation to exist before the proxy. For full determinism (knowing proxy address before any deployment), we need Solady's approach which has no code-length validation.

## Solution

Replace OZ `ERC1967Proxy` with Solady's `LibClone.deployERC1967()`. Solady's ERC1967 proxy:

- Has no code-length check on implementation
- Produces a 61-byte runtime proxy (gas-optimized)
- Supports deterministic CREATE2 deployment
- Compatible with Solady's `UUPSUpgradeable` (already in use)

---

## Migration Tasks

### Phase 1a: BaoFactory Updates

Update BaoFactory to use Solady LibClone instead of OZ ERC1967Proxy.

| ID   | Task                                                                       | Files            | Status  |
| ---- | -------------------------------------------------------------------------- | ---------------- | ------- |
| 1a.1 | Replace `ERC1967Proxy` import with `LibClone`                              | `BaoFactory.sol` | ✅ Done |
| 1a.2 | Update constructor to use `LibClone.deployERC1967()`                       | `BaoFactory.sol` | ✅ Done |
| 1a.3 | Ensure `BaoFactoryDeployed` event emission in constructor                  | `BaoFactory.sol` | ✅ Done |
| 1a.4 | Update `BaoFactoryLib.predictProxy()` to use nonce-based CREATE prediction | `BaoFactory.sol` | ✅ Done |
| 1a.5 | Update `BaoFactoryLib.predictAddresses()` accordingly                      | `BaoFactory.sol` | ✅ Done |
| 1a.6 | Remove `BAO_FACTORY_PROXY_SALT` (renamed to `BAO_FACTORY_SALT`)            | `BaoFactory.sol` | ✅ Done |

### Phase 1b: BaoFactory Upgrade Tests

Add tests demonstrating UUPS upgrades work correctly with the Solady proxy.

| ID   | Task                                                          | Files                                    | Status  |
| ---- | ------------------------------------------------------------- | ---------------------------------------- | ------- |
| 1b.1 | Create `BaoFactoryV2` mock for upgrade testing                | `lib/bao-factory/test/mocks/BaoFactoryV2.sol` | ✅ Done |
| 1b.2 | Test upgrade via `upgradeToAndCall()` maintains proxy address | `lib/bao-factory/test/BaoFactory.t.sol`       | ✅ Done |
| 1b.3 | Test upgraded contract retains state (operators, etc.)        | `lib/bao-factory/test/BaoFactory.t.sol`       | ✅ Done |
| 1b.4 | Test unauthorized upgrade reverts                             | `lib/bao-factory/test/BaoFactory.t.sol`       | ✅ Done |
| 1b.5 | Test upgrade to non-UUPS implementation reverts               | `lib/bao-factory/test/BaoFactory.t.sol`       | ✅ Done |

### Phase 1c: Security Attack Vector Tests

Demonstrate that known proxy/deployment attack vectors are mitigated.

#### Attack Vectors to Test

| Vector                             | Description                                                              | Mitigation                                                                                                                                                                                                                                                                                              |
| ---------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Address Squatting**              | Attacker deploys to predicted address before legitimate deployment       | Nick's Factory + deterministic salt ensures only valid deployment succeeds                                                                                                                                                                                                                              |
| **Implementation Takeover**        | Attacker calls functions on implementation directly                      | Implementation constructor deploys proxy; UUPS `onlyProxy` modifier                                                                                                                                                                                                                                     |
| **Proxy Re-initialization**        | Attacker reinitializes proxy after deployment                            | BaoFactory has no initializer; state is in storage, not initialization                                                                                                                                                                                                                                  |
| **Selfdestruct/CREATE2 Redeploy**  | Attacker selfdestructs impl and redeploys different code                 | Solady UUPSUpgradeable has no selfdestruct; hardcoded owner prevents upgrade to malicious impl                                                                                                                                                                                                          |
| **Delegatecall to Malicious Impl** | Attacker upgrades to impl that selfdestructs proxy                       | UUPS `_authorizeUpgrade` restricted to owner; `proxiableUUID` check prevents non-UUPS impl                                                                                                                                                                                                              |
| **Storage Collision**              | Upgrade to impl with different storage layout corrupts state             | V2 test verifies state retention; same storage layout enforced                                                                                                                                                                                                                                          |
| **Operator Privilege Escalation**  | Expired/removed operator attempts privileged action                      | `isCurrentOperator` checks expiry; only owner can upgrade                                                                                                                                                                                                                                               |
| **Front-running Deployment**       | Attacker front-runs to deploy different contract at predicted address    | Nick's Factory CREATE2 with specific salt; attacker cannot know our initcode                                                                                                                                                                                                                            |
| **Cross-chain Address Squatting**  | Attacker deploys to our predicted address on a different chain before us | Not mitigated by code - operational concern. However: (1) BaoFactory has hardcoded owner, so attacker's deployment would have wrong owner and be useless to them, (2) attacker cannot upgrade since they don't control owner address, (3) our legitimate deployment would fail, alerting us immediately |

#### Test Cases

| ID   | Test                                                               | Attack Vector                  | Files              | Status                                                   |
| ---- | ------------------------------------------------------------------ | ------------------------------ | ------------------ | -------------------------------------------------------- |
| 1c.1 | Verify implementation cannot be called directly for privileged ops | Implementation Takeover        | `BaoFactory.t.sol` | ✅ `testImplementationDirectCallsHaveDifferentAddresses` |
| 1c.2 | Verify proxy address is deterministic and matches prediction       | Address Squatting              | `BaoFactory.t.sol` | ✅ `testProxyAddressPrediction`                          |
| 1c.3 | Verify same initcode + salt from Nick's Factory is deterministic   | Address Squatting              | `BaoFactory.t.sol` | ✅ `testNicksFactoryDeploymentIsDeterministic`           |
| 1c.4 | Verify expired operator cannot deploy                              | Operator Privilege Escalation  | `BaoFactory.t.sol` | ✅ `testExpiredOperatorCannotDeploy`                     |
| 1c.5 | Verify removed operator cannot deploy                              | Operator Privilege Escalation  | `BaoFactory.t.sol` | ✅ `testRemovedOperatorCannotDeploy`                     |
| 1c.6 | Verify operator cannot upgrade (only owner)                        | Operator Privilege Escalation  | `BaoFactory.t.sol` | ✅ `testUpgradeUnauthorizedReverts`                      |
| 1c.7 | Verify deploying same salt twice reverts (no address reuse)        | CREATE3 Collision              | `BaoFactory.t.sol` | ✅ `testDeploySameSaltTwiceReverts`                      |
| 1c.8 | Verify upgrade to impl with wrong `proxiableUUID` fails            | Delegatecall to Malicious Impl | `BaoFactory.t.sol` | ✅ `testUpgradeToNonUUPSReverts`                         |
| 1c.9 | Verify storage layout preserved across upgrades                    | Storage Collision              | `BaoFactory.t.sol` | ✅ `testUpgradeRetainsOperatorState`                     |

### Phase 2: Bytecode Extraction Infrastructure

Create tooling to capture and verify bytecode for deterministic deployments.
**Note:** Must run after Phase 1a - bytecode extraction depends on updated BaoFactory code.

| ID  | Task                                              | Files                                      | Status  |
| --- | ------------------------------------------------- | ------------------------------------------ | ------- |
| 2.1 | Update `script/extract-bytecode` for Solady proxy | `script/extract-bytecode`                  | ✅ Done |
| 2.2 | Create `BaoFactoryBytecode.sol` with constants    | `script/deployment/BaoFactoryBytecode.sol` | ✅ Done |
| 2.3 | Add to package.json as yarn script                | `package.json`                             | ✅ Done |

**`BaoFactoryBytecode.sol` contents:**

- `BAO_FACTORY_CREATION_CODE` - hex constant for BaoFactory initcode
- `BAO_FACTORY_CREATION_CODE_HASH` - keccak256 of creation code for address prediction
- `ERC1967_PROXY_CODE_HASH` - re-exported from LibClone for convenience
- `proxyInitCode(address)` - helper to get proxy initcode for an implementation

### Phase 3: Deployment/DeploymentTesting Bytecode Integration

Integrate captured vs current bytecode selection into the Deployment hierarchy.

**Design:**

- `DeploymentInfrastructure._ensureBaoFactoryWithCreationCode(bytes)` - core logic accepting creation code
- `DeploymentInfrastructure._ensureBaoFactory()` - uses **captured bytecode** (production)
- `DeploymentInfrastructure._ensureBaoFactoryCurrentBuild()` - uses **current build** (dev/test)
- `DeploymentTesting._ensureBaoFactory()` - calls `_ensureBaoFactoryCurrentBuild()`

This ensures:

- Production deployments get deterministic addresses regardless of compiler version
- Tests work with current code changes without regenerating bytecode

| ID  | Task                                                               | Files                          | Status  |
| --- | ------------------------------------------------------------------ | ------------------------------ | ------- |
| 3.1 | Add `_ensureBaoFactoryWithCreationCode(bytes)` to infrastructure   | `DeploymentInfrastructure.sol` | ✅ Done |
| 3.2 | Add `_ensureBaoFactory()` using captured bytecode (production)     | `DeploymentInfrastructure.sol` | ✅ Done |
| 3.3 | Add `_ensureBaoFactoryCurrentBuild()` using current code           | `DeploymentInfrastructure.sol` | ✅ Done |
| 3.4 | Update `DeploymentTesting._ensureBaoFactory()` to use current code | `DeploymentTesting.sol`        | ✅ Done |
| 3.5 | Update prediction functions to accept creation code parameter      | `DeploymentInfrastructure.sol` | ✅ Done |

### Phase 4: DeploymentInfrastructure Cleanup

Previous updates already completed for Solady migration.

| ID  | Task                                              | Files                          | Status  |
| --- | ------------------------------------------------- | ------------------------------ | ------- |
| 4.1 | Update proxy verification to use Solady code hash | `DeploymentInfrastructure.sol` | ✅ Done |
| 4.2 | Remove OZ `ERC1967Proxy` import                   | `DeploymentInfrastructure.sol` | ✅ Done |

### Phase 5: Test Suite Updates

Update tests for new Solady proxy API.

| ID  | Task                                                             | Files                            | Status                      |
| --- | ---------------------------------------------------------------- | -------------------------------- | --------------------------- |
| 5.1 | Update setUp() for new proxy extraction method                   | `BaoFactory.t.sol`               | ✅ Done (unchanged - works) |
| 5.2 | Update `testProxyAddressPrediction()` for nonce-based prediction | `BaoFactory.t.sol`               | ✅ Done (unchanged - works) |
| 5.3 | Add test for Solady proxy code hash verification                 | `DeploymentInfrastructure.t.sol` | ✅ Done                     |
| 5.4 | Verify UUPS upgrade compatibility with Solady proxy              | `BaoFactory.t.sol`               | ✅ Done (Phase 1b)          |
| 5.5 | Update `testDeployProxyPayload()` to use Solady proxy            | `BaoFactory.t.sol`               | ✅ Done                     |
| 5.6 | Update `BaoFactoryLib` prediction tests                          | `BaoFactory.t.sol`               | ✅ Done (unchanged - works) |

### Phase 6: DeploymentInfrastructure Tests

| ID  | Task                                 | Files                            | Status                      |
| --- | ------------------------------------ | -------------------------------- | --------------------------- |
| 6.1 | Update proxy code verification tests | `DeploymentInfrastructure.t.sol` | ✅ Done                     |
| 6.2 | Update address prediction tests      | `DeploymentInfrastructure.t.sol` | ✅ Done (unchanged - works) |

### Phase 7: Documentation & Cleanup

| ID  | Task                                                     | Files                            | Status      |
| --- | -------------------------------------------------------- | -------------------------------- | ----------- |
| 7.1 | Remove OZ ERC1967Proxy from all BaoFactory-related files | Various                          | ✅ Done     |
| 7.2 | Update deployment architecture doc                       | `doc/deployment-architecture.md` | Not Started |
| 7.3 | Document bytecode extraction process                     | `doc/` or README                 | ✅ Done     |

---

## Technical Details

### Current Implementation (OZ)

```solidity
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

constructor() {
  address proxy = address(new ERC1967Proxy(address(this), ""));
  emit BaoFactoryDeployed(proxy, address(this));
}
```

**Proxy prediction (current) - CREATE2 based:**

```solidity
function predictProxy(bytes32 proxyCreationCodeHash) internal pure returns (address proxy) {
  bytes32 hash = keccak256(
    abi.encodePacked(bytes1(0xff), NICKS_FACTORY, BAO_FACTORY_PROXY_SALT, proxyCreationCodeHash)
  );
  proxy = address(uint160(uint256(hash)));
}
```

### New Implementation (Solady)

```solidity
import { LibClone } from "@solady/utils/LibClone.sol";
// UUPSUpgradeable already from Solady

constructor() {
  address proxy = LibClone.deployERC1967(address(this));
  emit BaoFactoryDeployed(proxy, address(this));
}
```

**Proxy prediction (new) - CREATE nonce-based:**

```solidity
/// @notice Predict proxy address from implementation address
/// @dev Uses RLP-encoded CREATE formula: keccak256(rlp([sender, nonce]))[12:]
///      Implementation deploys proxy as first CREATE (nonce=1)
function predictProxy(address implementation) internal pure returns (address proxy) {
  // RLP encoding for [address, 1]: 0xd6 0x94 <20-byte-address> 0x01
  bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), implementation, bytes1(0x01)));
  proxy = address(uint160(uint256(hash)));
}
```

### Key Differences

| Aspect             | OZ ERC1967Proxy                   | Solady LibClone.deployERC1967 |
| ------------------ | --------------------------------- | ----------------------------- |
| Runtime size       | ~48 bytes                         | 61 bytes                      |
| Code-length check  | Yes (reverts if impl has no code) | No                            |
| Proxy creation     | CREATE (in constructor)           | CREATE (via LibClone)         |
| Address prediction | CREATE nonce-based                | CREATE nonce-based (same)     |
| Gas (deployment)   | Higher                            | Lower                         |
| Gas (runtime)      | Similar                           | Slightly better               |

### Solady ERC1967 Proxy Runtime Code

The Solady ERC1967 proxy is a 61-byte minimal proxy:

- Code hash: `0xaaa52c8cc8a0e3fd27ce756cc6b4e70c51423e9b597b11f32d3e49f8b1fc890d`
- Stored in `LibClone.ERC1967_CODE_HASH`

---

## BaoFactoryBytecode.sol Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title BaoFactoryBytecode
/// @notice Captured bytecode for deterministic BaoFactory deployment
/// @dev Auto-generated by script/extract-bytecode - DO NOT EDIT MANUALLY
library BaoFactoryBytecode {
    /// @dev BaoFactory creation code (initcode)
    bytes internal constant BAO_FACTORY_CREATION_CODE = hex"...";

    /// @dev Solady ERC1967 proxy runtime code (61 bytes)
    ///      From LibClone.ERC1967_CODE_HASH
    bytes internal constant ERC1967_PROXY_RUNTIME_CODE = hex"...";

    /// @dev keccak256(ERC1967_PROXY_RUNTIME_CODE)
    ///      Should equal LibClone.ERC1967_CODE_HASH
    bytes32 internal constant ERC1967_PROXY_CODE_HASH =
        0xaaa52c8cc8a0e3fd27ce756cc6b4e70c51423e9b597b11f32d3e49f8b1fc890d;
}
```

---

## extract-bytecode Script Updates

The existing `script/extract-bytecode` bash script needs updates:

1. **Remove OZ ERC1967Proxy extraction** - no longer needed
2. **Add Solady proxy runtime code** - extract from LibClone constant or hardcode
3. **Verify code hash** - ensure extracted bytecode matches `LibClone.ERC1967_CODE_HASH`
4. **Update output format** - new `BaoFactoryBytecode.sol` structure

---

## Risks & Mitigations

| Risk                                   | Mitigation                                      |
| -------------------------------------- | ----------------------------------------------- |
| Solady proxy bytecode differs from OZ  | Tests verify ERC1967 storage slot compatibility |
| ERC1967 storage slot compatibility     | Same slot (`0x360894...`), verified in LibClone |
| UUPSUpgradeable compatibility          | Already using Solady's UUPSUpgradeable          |
| Production deployments affected        | BaoFactory not yet deployed to mainnet          |
| Bytecode changes with compiler updates | Captured bytecode ensures determinism           |

---

## Acceptance Criteria

1. ✅ `script/extract-bytecode` generates `BaoFactoryBytecode.sol`
2. ✅ All `BaoFactory.t.sol` tests pass
3. ✅ All `DeploymentInfrastructure.t.sol` tests pass
4. ✅ Proxy address prediction matches actual deployment
5. ✅ Proxy code hash matches `LibClone.ERC1967_CODE_HASH`
6. ✅ UUPS upgrades work through the new proxy
7. ✅ No OZ ERC1967Proxy imports in BaoFactory-related files
8. ✅ Gas usage same or better

---

## Execution Order

```
Phase 1a: BaoFactory Updates (code changes first)
    1a.1 → 1a.2 → 1a.3 → 1a.4 → 1a.5 → 1a.6

Phase 1b: BaoFactory Upgrade Tests
    1b.1 → 1b.2 → 1b.3 → 1b.4 → 1b.5

Phase 2: Bytecode Infrastructure (extract after code is updated)
    2.1 → 2.2 → 2.3

Phase 3: DeploymentInfrastructure
    3.1 → 3.2 → 3.3 → 3.4 → 3.5

Phase 4: Test Suite (can run in parallel with Phase 5)
    4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6

Phase 5: Infrastructure Tests
    5.1 → 5.2

Phase 6: Cleanup
    6.1 → 6.2 → 6.3
```

---

## Out of Scope

- Changing other deployment infrastructure (e.g., `Deployment.sol` proxy deployment for non-BaoFactory contracts)
- Bootstrap pattern for pre-deployment address prediction (future enhancement)
- ERC1967I variant (with implementation getter via 1-byte calldata)
