# Deployment Framework

## Overview

Unified deployment registry system (`script/deployment/Deployment.sol`) providing deterministic cross-chain contract addresses via CREATE3 with deployer context injection.

**Key Features**:
- Deterministic proxy addresses across chains using CREATE3
- Injected deployer context (production vs test)
- Bootstrap stub pattern for BaoOwnable compatibility
- Incremental deployment with JSON state preservation
- Type-safe deployment workflow (Foundry and Wake)

## Quick Start

### Deployer Context Pattern

The system uses **injected deployer context** for deterministic addresses:
- **CREATE3** calculates: `hash(deployer, salt)`
- **DEPLOYER_CONTEXT** passed to `Deployment` constructor
- Same context + same salt = same addresses across chains

### Production Setup

```solidity
// 1. Deploy harness via Nick's Factory (0x4e59b44847b379578588920cA78FbF26c0B4956C)
bytes32 salt = keccak256("your-protocol-harness-v1");
bytes memory deployData = abi.encodePacked(salt, type(YourDeployment).creationCode);
(bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
address harnessAddr = address(uint160(uint256(bytes32(returnData))));

// 2. Harness uses its own address as deployer context
contract YourDeployment is DeploymentFoundry {
    constructor(address deployerContext) DeploymentFoundry(vm, deployerContext) {}
    
    function deployProtocol() external {
        start(owner, "mainnet", "v1.0.0", "protocol-salt");
        deployProxy("token", "TokenImpl", initData);
        finish();
    }
}

// 3. Same harness address on all chains = same contract addresses
```

### Test Setup

```solidity
// Simple approach (current tests)
contract TestDeployment is Deployment {
    constructor() Deployment(address(0)) {} // Defaults to address(this)
}

function setUp() public {
    deployment = new TestDeployment();
    deployment.start(address(this), "test", "v1", "test-salt");
}
```

**Benefits**:
✅ Identical code for production and tests
✅ Simple constructor parameter switch
✅ Predictable addresses before deployment
✅ Cross-chain determinism

## Architecture

### Core Contract: `Deployment.sol`

**Location**: `script/deployment/Deployment.sol`

**Design Principles**:

1. All proxies use CREATE3 (deterministic cross-chain)
2. All libraries use CREATE (standard opcode)
3. Contracts use CREATE (for mocks, tests, quick deployments)
4. Deployer context injection (production vs test)
5. Automatic JSON persistence with structured metadata
6. Dependency enforcement via `get()` errors

### Rationalized Test Structure

**Core Functionality Tests:**

- `DeploymentBasic.t.sol` - Basic contract registration and operations
- `DeploymentProxy.t.sol` - CREATE3 proxy deployment testing
- `DeploymentLibrary.t.sol` - CREATE library deployment (merged from LibraryDeployment.t.sol)
- `DeploymentParameter.t.sol` - Typed parameter storage
- `DeploymentDependency.t.sol` - Inter-contract dependencies

**Persistence Tests:**

- `DeploymentJson.t.sol` - File I/O persistence
- `DeploymentJsonString.t.sol` - In-memory JSON serialization
- `DeploymentJsonRoundTrip.t.sol` - Serialization fidelity testing

**Workflow Tests:**

- `DeploymentWorkflow.t.sol` - Complete deployment scenarios (split from DeploymentIntegration.t.sol)
- `DeploymentUpgrade.t.sol` - Proxy upgrade workflows (split from DeploymentIntegration.t.sol)

**Mock Infrastructure:**

- `test/mocks/basic/` - Simple test contracts (MockContract, MockImplementation, MockDependencies)
- `test/mocks/upgradeable/` - UUPS proxy implementations (MockCounter, MockOracle, MockMinter, MockGeneric)
- `test/mocks/tokens/` - Token mock contracts (MockERC20)
- `test/mocks/TestLibraries.sol` - Libraries for testing

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

## Usage Patterns

### Basic Deployment

```solidity
contract MyDeployment is Deployment {
    function deploy() external {
        // Start session (creates bootstrap stub)
        start(msg.sender, "mainnet", "v1.0.0", "protocol-salt");

        // Use existing contracts
        address wstETH = useExisting("wstETH", 0x7f39C581...);

        // Deploy contracts (enforce dependencies via get())
        address oracle = get("oracle");  // Reverts if not deployed

        // Deploy proxy (deterministic via CREATE3)
        address minter = deployProxy(
            "minter",
            minterImplementation,
            initData
        );

        // Finish and save
        finish();
        // Production: deployments/mainnet/protocol-salt.json
        // Tests: results/deployments/protocol-salt.json
    }
}
```

### Production Deployment Workflow

1. **Deploy Harness via Nick's Factory** (one-time per chain):
   ```solidity
   address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
   bytes32 salt = keccak256("your-protocol-harness-v1");
   
   // Predict address first
   bytes32 hash = keccak256(abi.encodePacked(
       bytes1(0xff), NICKS_FACTORY, salt, 
       keccak256(type(YourDeployment).creationCode)
   ));
   address predicted = address(uint160(uint256(hash)));
   ```

2. **Deploy contracts** using identical system salt across chains
3. **Repeat on other chains** - same harness address + same salt = same contract addresses

### Incremental Deployment

```solidity
// Phase 1: Initial deployment
deployment.start(owner, "mainnet", "v1", "protocol-v1");
deployment.deployProxy("token", tokenImpl, initData);
deployment.finish();

// Phase 2: Resume and add more
deployment.resume("mainnet", "protocol-v1");
deployment.deployProxy("vault", vaultImpl, initData);
deployment.finish();
```

## Production Simulation in Tests

The architecture supports full production simulation using `MockNicksFactory`:

```solidity
import { MockNicksFactory } from "test/mocks/deployment/MockNicksFactory.sol";

address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
bytes32 constant SALT = keccak256("your-protocol-harness-v1");

function setUp() public {
    // Mock Nick's Factory at real address
    MockNicksFactory mockFactory = new MockNicksFactory();
    vm.etch(NICKS_FACTORY, address(mockFactory).code);
    
    // Deploy harness via mock factory (same as production)
    bytes memory deployData = abi.encodePacked(SALT, type(YourDeployment).creationCode);
    (bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
    address harnessAddr = address(uint160(uint256(bytes32(returnData))));
    
    // Use deployed harness (validates full production flow)
    deployment = YourDeployment(harnessAddr);
    deployment.start(owner, "test", "v1", "test-salt");
}
```

**Note**: Architecture supports this but not yet implemented in current test suite.

## See Also

- **Full Design**: [deployment-system.md](../../doc/deployment-system.md) - Complete architecture and design decisions
- **Mock Factory**: [MockNicksFactory.sol](../mocks/deployment/MockNicksFactory.sol) - Factory mock for testing

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
