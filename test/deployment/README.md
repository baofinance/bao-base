# Deployment Framework - Implementation Summary

## Overview

Successfully implemented a unified deployment registry system (`src/deployment/Deployment.sol`) that replaces the previous three-layer inheritance structure (BaseDeployment → CREATE3Deployment/CREATEDeployment → HarborDeployment).

## Architecture

### Core Contract: `Deployment.sol`

**Location**: `src/deployment/Deployment.sol`

**Design Principles**:

1. All proxies use CREATE3 (deterministic cross-chain)
2. All libraries use CREATE (standard opcode)
3. Contracts use CREATE (for mocks, tests, quick deployments)
4. Internal registration - derived classes just deploy
5. Automatic JSON persistence with structured metadata
6. Dependency enforcement via `get()` errors

### Entry Types

The system tracks four types of deployments:

1. **ContractEntry** - Direct deployments, mocks, test contracts
2. **ProxyEntry** - UUPS proxies (always CREATE3)
3. **ImplementationEntry** - Implementation contracts backing proxies
4. **LibraryEntry** - Libraries (always CREATE)

### Embedded Structs

Uses composition pattern for clean code:

- **DeploymentInfo** - Common fields (addr, contractType, contractPath, txHash, blockNumber, category)
- **CREATE3Info** - Salt data for deterministic deployment
- **ProxyInfo** - Implementation reference for proxies

### Public API

**Deployment Methods** (public):

- `deployProxy(key, implementation, initData, saltString)` - Deploy UUPS proxy via CREATE3
- `deployLibrary(key, bytecode, contractType, contractPath)` - Deploy library via CREATE
- `deployContract(key, addr, contractType, contractPath, category)` - Register deployed contract
- `useExisting(key, addr)` - Register external/existing contract

**Registry Methods** (public):

- `get(key)` - Get address (reverts if not deployed - enforces dependencies)
- `has(key)` - Check if contract exists
- `keys()` - Get all registered keys
- `getEntryType(key)` - Get entry type for a key

**Metadata Methods** (public):

- `startDeployment(deployer, network, version)` - Initialize deployment session
- `finishDeployment()` - Mark deployment as complete
- `getMetadata()` - Get deployment metadata

**Persistence Methods** (public):

- `saveToJson(filepath)` - Save deployment to JSON
- `loadFromJson(filepath)` - Load deployment from JSON

**Internal Methods**:

- `_registerContract()`, `_registerProxy()`, `_registerImplementation()`, `_registerLibrary()`
- Component serializers: `_serializeDeploymentInfo()`, `_serializeCREATE3Info()`, `_serializeProxyInfo()`
- Entry serializers: `_serializeContractToObject()`, `_serializeProxyToObject()`, etc.

## Test Coverage

### Test Files Created

All tests in `test/deployment/`:

1. **DeploymentBasic.t.sol** (10 tests)
   - Basic deployment functionality
   - Contract registration
   - Error handling
   - Metadata tracking

2. **DeploymentDependency.t.sol** (7 tests)
   - Dependency management
   - get() enforcement
   - Chained dependencies
   - Complex dependency graphs

3. **DeploymentProxy.t.sol** (7 tests)
   - UUPS proxy deployment
   - CREATE3 deterministic addresses
   - Address prediction
   - Multiple proxies

4. **DeploymentLibrary.t.sol** (4 tests)
   - Library deployment via CREATE
   - Non-deterministic addresses
   - Multiple libraries

5. **DeploymentJson.t.sol** (9 tests)
   - JSON serialization
   - JSON deserialization
   - Save/load round-trip
   - Metadata persistence
   - Incremental deployment

6. **DeploymentIntegration.t.sol** (6 tests)
   - End-to-end system deployment
   - Multiple contract types
   - Existing contracts integration
   - Complex dependency chains
   - Multiple proxies with same implementation

7. **DeploymentComparison.t.sol** (13 tests)
   - CREATE vs CREATE3 comparison
   - Determinism testing
   - Gas benchmarking

### Test Results

**Total: 56 tests, 56 passing (100%)**

```
╭---------------------------+--------+--------+---------╮
| Test Suite                | Passed | Failed | Skipped |
+=======================================================+
| DeploymentBasicTest       | 10     | 0      | 0       |
| DeploymentComparisonTest  | 13     | 0      | 0       |
| DeploymentDependencyTest  | 7      | 0      | 0       |
| DeploymentIntegrationTest | 6      | 0      | 0       |
| DeploymentJsonTest        | 9      | 0      | 0       |
| DeploymentLibraryTest     | 4      | 0      | 0       |
| DeploymentProxyTest       | 7      | 0      | 0       |
╰---------------------------+--------+--------+---------╯
```

### Test Coverage Areas

✅ **Basic Functionality**

- Contract deployment and registration
- Multiple contract types
- useExisting() for external contracts
- Keys and has() queries

✅ **Dependency Management**

- Simple dependencies (A depends on B)
- Chained dependencies (A → B → C)
- Complex graphs (multiple dependencies)
- Error on missing dependencies
- Multiple dependents on same contract

✅ **Proxy Deployment**

- CREATE3 deterministic deployment
- Address prediction before deployment
- Multiple proxies with different salts
- Initialization with data
- Proxy functionality verification

✅ **Library Deployment**

- CREATE standard deployment
- Non-deterministic addresses
- Multiple libraries
- Library bytecode handling

✅ **JSON Persistence**

- Save empty deployment
- Save all entry types
- Load and verify addresses
- Round-trip save/load
- Incremental deployment (load, add more, save)
- Metadata persistence (timestamps, block numbers)

✅ **Integration**

- Full system deployment
- Mixed entry types
- Existing + new contracts
- Complex dependency chains
- Same implementation, multiple proxies

✅ **Error Handling**

- ContractNotFound
- ContractAlreadyExists
- InvalidAddress
- DependencyNotMet
- SaltRequired
- ImplementationRequired

## JSON Output Format

Example structure:

```json
{
  "deployer": {
    "address": "0x..."
  },
  "metadata": {
    "startedAt": 1234567890,
    "finishedAt": 1234567900,
    "startBlock": 100,
    "network": "mainnet",
    "version": "v1.0.0"
  },
  "deployment": {
    "contractKey": {
      "address": "0x...",
      "contractType": "MockERC20",
      "contractPath": "test/MockERC20.sol",
      "category": "mock",
      "blockNumber": 100,
      "deployer": "0x..."
    },
    "proxyKey": {
      "address": "0x...",
      "contractType": "ERC1967Proxy",
      "contractPath": "lib/.../ERC1967Proxy.sol",
      "category": "UUPS proxy",
      "salt": "0x...",
      "saltString": "proxy-v1",
      "blockNumber": 101,
      "deployer": "0x..."
    },
    "libKey": {
      "address": "0x...",
      "contractType": "ConfigLib",
      "contractPath": "src/lib/ConfigLib.sol",
      "category": "library",
      "blockNumber": 102,
      "deployer": "0x..."
    }
  }
}
```

## Usage Pattern

```solidity
contract MyDeployment is Deployment {
    function deploy() external {
        // Start session
        startDeployment(msg.sender, "mainnet", "v1.0.0");

        // Use existing contracts
        address wstETH = useExisting("wstETH", 0x7f39C581...);

        // Deploy contracts (enforce dependencies via get())
        address oracle = get("oracle");  // Reverts if not deployed

        // Deploy proxy
        address minter = deployProxy(
            "minter",
            minterImplementation,
            initData,
            "minter-v1"
        );

        // Finish and save
        finishDeployment();
        saveToJson("results/deployment/mainnet.json");
    }
}
```

## Next Steps

1. **Harbor Layer**: Create `HarborDeployment` that extends `Deployment` and uses HarborConstants for type-safe keys
2. **Migrate Tests**: Update existing Harbor tests to use new framework
3. **Role Tracking**: Add `recordRoleGrant()` for tracking role assignments
4. **TypeScript Integration**: Generate TypeScript interfaces and deployment scripts

## Dependencies

- Solady CREATE3 for deterministic deployment
- OpenZeppelin ERC1967Proxy for UUPS proxies
- Forge VM cheatcodes for JSON serialization

## File Structure

```
src/deployment/
  └── Deployment.sol (unified base contract)

test/deployment/
  ├── DeploymentBasic.t.sol
  ├── DeploymentDependency.t.sol
  ├── DeploymentProxy.t.sol
  ├── DeploymentLibrary.t.sol
  ├── DeploymentJson.t.sol
  ├── DeploymentIntegration.t.sol
  └── DeploymentComparison.t.sol
```

## Notes

- Tests use unique file paths per test to support parallel execution
- Validation happens at registration time (fail-fast), not at serialization
- CREATE3 uses inline assembly for salt hashing (avoids linter warning)
- All serializer functions are internal/private - clean public API
