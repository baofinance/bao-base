# Nick's Factory Integration Plan

## Overview

Integrate Nick's Factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) as the CREATE3 deployer for true cross-chain deterministic deployments, while maintaining flexibility for multiple test environments.

## Current State

- Solady's `CREATE3` library called directly from `Deployment` contract
- `CREATE3.deployDeterministic()` uses `address(this)` as deployer context
- Nick's Factory constant exists but unused
- `MockNicksFactory` exists but not integrated
- Tests use `address(0)` → `address(this)` pattern for `DEPLOYER_CONTEXT`

## Target Environments

### 1. **Pure Test Environment (Foundry Test)**

- **Runtime**: Foundry's internal EVM (`forge test`)
- **Factory**: Mock factory or self-deployment
- **Use Case**: Fast unit tests, no external dependencies
- **Setup**: Automatic, no configuration needed

### 2. **Forked Test Environment (Foundry Test)**

- **Runtime**: Foundry's internal EVM with fork (`forge test --fork-url`)
- **Factory**: Real Nick's Factory (already deployed on fork)
- **Use Case**: Integration tests against real factory behavior
- **Setup**: Specify fork URL, factory auto-detected

### 3. **Raw Anvil (Foundry Script)**

- **Runtime**: Local anvil instance (`anvil`)
- **Factory**: Deploy mock factory or deploy real factory bytecode
- **Use Case**: Local development, deployment rehearsal
- **Setup**: Run anvil, deploy factory in script preamble

### 4. **Forked Anvil (Foundry Script)**

- **Runtime**: Forked anvil (`anvil --fork-url`)
- **Factory**: Real Nick's Factory from fork
- **Use Case**: Production deployment rehearsal on mainnet state
- **Setup**: Run forked anvil, factory already present

### 5. **Production Networks**

- **Runtime**: Live blockchain
- **Factory**: Real Nick's Factory (already deployed)
- **Use Case**: Actual deployments
- **Setup**: None, factory exists

---

## Architecture

### Factory Abstraction Layer

```solidity
abstract contract Deployment {
  address internal immutable DEPLOYER_CONTEXT;
  address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

  // Virtual function for factory selection
  function _getCreate3Factory() internal view virtual returns (address);

  // Deploy through factory
  function _deployViaFactory(bytes memory creationCode, bytes32 salt) internal returns (address deployed);

  // Predict using factory as deployer
  function predictProxyAddress(string memory proxyKey) public view returns (address);
}
```

### Environment Detection Strategy

```solidity
function _getCreate3Factory() internal view virtual returns (address) {
  // 1. Check if Nick's Factory has code (production/fork)
  if (NICKS_FACTORY.code.length > 0) {
    return NICKS_FACTORY;
  }

  // 2. Fallback to self-deployment for pure test environment
  return address(this);
}
```

**Test Harness Override:**

```solidity
contract TestDeployment is Deployment {
  address private _mockFactory;

  function _getCreate3Factory() internal view virtual override returns (address) {
    // Explicit mock takes precedence
    if (_mockFactory != address(0)) {
      return _mockFactory;
    }

    // Otherwise use parent logic (checks for real factory)
    return super._getCreate3Factory();
  }

  function setMockFactory(address factory) public {
    _mockFactory = factory;
  }
}
```

---

## Environment-Specific Patterns

### Pattern 1: Pure Test (Foundry Test - Internal EVM)

**Characteristics:**

- Fast execution
- No external dependencies
- Isolated from chain state
- Uses mock factory

**Setup:**

```solidity
contract MyTest is Test {
  TestDeployment deployment;

  function setUp() public {
    // Option A: Use mock factory
    MockNicksFactory mockFactory = new MockNicksFactory();
    deployment = new TestDeployment();
    deployment.setMockFactory(address(mockFactory));

    // Option B: Use self-deployment (no mock)
    deployment = new TestDeployment();
    // Factory will default to address(deployment)
  }
}
```

**Factory Resolution:**

1. Check `_mockFactory` → set to mock address
2. Check `NICKS_FACTORY.code.length` → 0 (no code)
3. Return `address(this)` → self-deployment

### Pattern 2: Forked Test (Foundry Test - Fork)

**Characteristics:**

- Tests against real chain state
- Real Nick's Factory available
- Validates production-like behavior
- Slower than pure tests

**Setup:**

```solidity
contract MyForkTest is Test {
  TestDeployment deployment;

  function setUp() public {
    // No special setup needed!
    deployment = new TestDeployment();
    // Factory auto-detected from fork
  }
}
```

**Run Command:**

```bash
forge test --fork-url $MAINNET_RPC_URL --match-contract MyForkTest
```

**Factory Resolution:**

1. Check `_mockFactory` → address(0) (not set)
2. Check `NICKS_FACTORY.code.length` → >0 (exists on fork)
3. Return `NICKS_FACTORY` → use real factory

### Pattern 3: Raw Anvil (Foundry Script)

**Characteristics:**

- Clean slate local chain
- Fast iteration
- Requires factory deployment
- Full deployment rehearsal

**Setup - Option A: Deploy Mock Factory in Script**

```solidity
contract DeployToAnvil is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy mock factory first
        MockNicksFactory mockFactory = new MockNicksFactory();

        // Deploy deployment harness
        MyDeployment deployment = new MyDeployment(address(0));
        deployment.setMockFactory(address(mockFactory));

        // Now deploy system
        deployment.start(...);
        deployment.deployProxy(...);
        deployment.finish();

        vm.stopBroadcast();
    }
}
```

**Setup - Option B: Etch Real Factory Bytecode**

```solidity
contract DeployToAnvil is Script {
    function run() public {
        vm.startBroadcast();

        // Etch real Nick's Factory bytecode at canonical address
        bytes memory factoryCode = /* real factory bytecode */;
        vm.etch(NICKS_FACTORY, factoryCode);

        // Deploy deployment harness
        MyDeployment deployment = new MyDeployment(address(0));
        // Factory auto-detected

        // Deploy system
        deployment.start(...);
        // ...

        vm.stopBroadcast();
    }
}
```

**Run Command:**

```bash
# Start anvil
anvil

# Run script
forge script script/DeployToAnvil.s.sol --rpc-url http://localhost:8545 --broadcast
```

**Factory Resolution:**

1. Check `_mockFactory` → set in script (Option A) or address(0) (Option B)
2. Check `NICKS_FACTORY.code.length` → >0 if etched (Option B)
3. Return appropriate factory

### Pattern 4: Forked Anvil (Foundry Script)

**Characteristics:**

- Fork of production state
- Real Nick's Factory available
- Safe production deployment rehearsal
- Tests against actual on-chain state

**Setup:**

```solidity
contract DeployToForkedAnvil is Script {
    function run() public {
        vm.startBroadcast();

        // No factory setup needed - already exists on fork
        MyDeployment deployment = new MyDeployment(address(0));

        // Deploy system exactly as production
        deployment.start(...);
        deployment.deployProxy(...);
        deployment.finish();

        vm.stopBroadcast();
    }
}
```

**Run Commands:**

```bash
# Start forked anvil
anvil --fork-url $MAINNET_RPC_URL

# Run script
forge script script/DeployToForkedAnvil.s.sol \
    --rpc-url http://localhost:8545 \
    --broadcast
```

**Factory Resolution:**

1. Check `_mockFactory` → address(0) (not set)
2. Check `NICKS_FACTORY.code.length` → >0 (exists on fork)
3. Return `NICKS_FACTORY` → use real factory

### Pattern 5: Production Deployment

**Characteristics:**

- Live blockchain
- Real Nick's Factory
- Permanent deployment
- High gas costs

**Setup:**

```solidity
contract ProductionDeploy is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy via Nick's Factory for cross-chain determinism
        bytes32 harnessSalt = keccak256("bao-deployment-harness-v1");
        bytes memory harnessCreationCode = type(MyDeployment).creationCode;

        // Predict harness address
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                NICKS_FACTORY,
                harnessSalt,
                keccak256(harnessCreationCode)
            )
        );
        address predictedHarness = address(uint160(uint256(hash)));

        // Deploy harness via Nick's Factory
        bytes memory deployData = abi.encodePacked(harnessSalt, harnessCreationCode);
        (bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
        require(success, "Harness deployment failed");

        address harnessAddr = address(uint160(uint256(bytes32(returnData))));
        require(harnessAddr == predictedHarness, "Address mismatch");

        // Use harness to deploy system
        MyDeployment deployment = MyDeployment(harnessAddr);
        deployment.start(...);
        deployment.deployProxy(...);
        deployment.finish();

        vm.stopBroadcast();
    }
}
```

**Run Command:**

```bash
forge script script/ProductionDeploy.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify
```

**Factory Resolution:**

1. Check `_mockFactory` → address(0) (TestDeployment not used in production)
2. Check `NICKS_FACTORY.code.length` → >0 (exists on mainnet)
3. Return `NICKS_FACTORY` → use real factory

---

## Implementation Details

### 1. Factory Deployment Method

**Current (Direct CREATE3):**

```solidity
address proxy = CREATE3.deployDeterministic(proxyCreationCode, salt);
```

**New (Via Factory):**

```solidity
function _deployViaFactory(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
  address factory = _getCreate3Factory();

  if (factory == address(this)) {
    // Self-deployment fallback (old behavior)
    deployed = CREATE3.deployDeterministic(creationCode, salt);
  } else {
    // Deploy through factory
    bytes memory deployData = abi.encodePacked(salt, creationCode);
    (bool success, bytes memory returnData) = factory.call(deployData);
    require(success, "Factory deployment failed");
    deployed = address(uint160(uint256(bytes32(returnData))));
  }

  require(deployed != address(0), "Deployment failed");
  require(deployed.code.length > 0, "No code at deployment address");
}
```

### 2. Address Prediction Update

**Current:**

```solidity
proxy = CREATE3.predictDeterministicAddress(salt, DEPLOYER_CONTEXT);
```

**New:**

```solidity
function predictProxyAddress(string memory proxyKey) public view returns (address proxy) {
  bytes32 salt = _computeSalt(proxyKey);
  address factory = _getCreate3Factory();
  proxy = CREATE3.predictDeterministicAddress(salt, factory);
}
```

### 3. Registry Update

**Update `_registerProxy` to record actual factory:**

```solidity
_registerProxy(
    proxyKey,
    proxy,
    implementationKey,
    salt,
    saltString,
    "UUPS",
    _getCreate3Factory(), // Record actual factory used
    _runs[_runs.length - 1].deployer
);
```

### 4. Mock Factory Enhancement

**Ensure `MockNicksFactory` matches real factory interface:**

```solidity
contract MockNicksFactory {
  event ContractDeployed(address indexed deployed, bytes32 indexed salt);

  fallback(bytes calldata) external payable returns (bytes memory) {
    require(msg.data.length >= 32, "Invalid calldata");

    bytes32 salt;
    bytes memory bytecode;

    assembly {
      salt := calldataload(0)
      let bytecodeLength := sub(calldatasize(), 32)
      bytecode := mload(0x40)
      mstore(bytecode, bytecodeLength)
      calldatacopy(add(bytecode, 0x20), 32, bytecodeLength)
      mstore(0x40, add(add(bytecode, 0x20), bytecodeLength))
    }

    address deployed;
    assembly {
      deployed := create2(callvalue(), add(bytecode, 0x20), mload(bytecode), salt)
    }

    require(deployed != address(0), "CREATE2 failed");
    emit ContractDeployed(deployed, salt);

    return abi.encodePacked(bytes32(uint256(uint160(deployed))));
  }
}
```

---

## Test Strategy

### Test Categories

**1. Unit Tests (Pure Environment)**

- Test individual deployment operations
- Fast execution, no chain state needed
- Use mock factory or self-deployment
- File: `test/deployment/Deployment*.t.sol` (existing)

**2. Integration Tests (Forked Environment)**

- Test against real factory behavior
- Validate address predictions match reality
- Test with actual chain state
- File: `test/deployment/DeploymentFork.t.sol` (new)

**3. Script Tests (Raw Anvil)**

- Test full deployment scripts
- Rehearse deployment procedures
- Validate factory setup options
- File: `script/test/AnvilDeploy.t.sol` (new)

**4. Fork Script Tests (Forked Anvil)**

- Production deployment rehearsal
- Validate against mainnet state
- Test upgrade scenarios
- File: `script/test/ForkedAnvilDeploy.t.sol` (new)

### Test Matrix

| Test Type   | Environment  | Factory     | Run Command                                             |
| ----------- | ------------ | ----------- | ------------------------------------------------------- |
| Unit        | Internal EVM | Mock        | `forge test --match-path "test/deployment/*.t.sol"`     |
| Fork Test   | Forked EVM   | Real        | `forge test --fork-url $RPC --match-contract Fork`      |
| Script Test | Raw Anvil    | Mock/Etched | `forge script --rpc-url http://localhost:8545`          |
| Fork Script | Forked Anvil | Real        | `forge script --rpc-url http://localhost:8545` (forked) |
| Production  | Live Chain   | Real        | `forge script --rpc-url $RPC --broadcast`               |

---

## Migration Plan

### Phase 1: Add Factory Abstraction (No Breaking Changes)

**Files:**

- `script/deployment/Deployment.sol`
  - Add `_getCreate3Factory()` virtual function
  - Add `_deployViaFactory()` internal method
  - Keep existing `deployProxy()` signature

**Changes:**

```solidity
// Add factory selection
function _getCreate3Factory() internal view virtual returns (address) {
  if (NICKS_FACTORY.code.length > 0) {
    return NICKS_FACTORY;
  }
  return address(this);
}

// Add factory deployment method
function _deployViaFactory(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
  // Implementation as shown above
}
```

**Testing:**

- All existing tests pass unchanged
- No behavior changes yet

### Phase 2: Update Internal Deployment Calls

**Files:**

- `script/deployment/Deployment.sol`
  - Replace `CREATE3.deployDeterministic()` with `_deployViaFactory()`
  - Update `predictProxyAddress()` to use `_getCreate3Factory()`

**Changes:**

```solidity
// In deployProxy()
- address proxy = CREATE3.deployDeterministic(proxyCreationCode, salt);
+ address proxy = _deployViaFactory(proxyCreationCode, salt);

// In predictProxyAddress()
- proxy = CREATE3.predictDeterministicAddress(salt, DEPLOYER_CONTEXT);
+ proxy = CREATE3.predictDeterministicAddress(salt, _getCreate3Factory());
```

**Testing:**

- All existing tests still pass
- Behavior identical in test environment (factory defaults to `address(this)`)

### Phase 3: Add Test Harness Mock Factory Support

**Files:**

- `test/deployment/TestDeployment.sol`
  - Add `_mockFactory` storage variable
  - Override `_getCreate3Factory()`
  - Add `setMockFactory()` public method
  - Add `setupMockFactory()` helper

**Changes:**

```solidity
contract TestDeployment is Deployment {
  address private _mockFactory;

  function _getCreate3Factory() internal view virtual override returns (address) {
    if (_mockFactory != address(0)) return _mockFactory;
    return super._getCreate3Factory();
  }

  function setMockFactory(address factory) public {
    _mockFactory = factory;
  }

  function setupMockFactory() public {
    MockNicksFactory mockFactory = new MockNicksFactory();
    setMockFactory(address(mockFactory));
  }
}
```

**Testing:**

- Add tests demonstrating mock factory usage
- Verify factory selection logic

### Phase 4: Update Registry to Record Factory

**Files:**

- `script/deployment/Deployment.sol`
  - Update `_registerProxy()` calls to pass actual factory address

**Changes:**

```solidity
_registerProxy(
    proxyKey,
    proxy,
    implementationKey,
    salt,
    saltString,
    "UUPS",
-   _metadata.deployer,
+   _getCreate3Factory(),
    _runs[_runs.length - 1].deployer
);
```

**Testing:**

- Verify factory address appears in JSON output
- Check registry contains correct factory reference

### Phase 5: Add Fork Tests

**Files:**

- `test/deployment/DeploymentFork.t.sol` (new)

**Content:**

```solidity
contract DeploymentForkTest is Test {
    TestDeployment deployment;

    function setUp() public {
        // Verify we're on a fork
        require(
            NICKS_FACTORY.code.length > 0,
            "Must run with --fork-url for this test"
        );

        deployment = new TestDeployment();
        deployment.start(...);
    }

    function test_DeployViaRealFactory() public {
        // Deploy proxy
        address proxy = deployment.deployProxy(...);

        // Verify deployment
        assertTrue(proxy.code.length > 0);

        // Verify factory was used
        assertEq(deployment._getCreate3Factory(), NICKS_FACTORY);
    }

    function test_AddressPredictionMatchesDeployment() public {
        // Predict address
        address predicted = deployment.predictProxyAddress("test");

        // Deploy
        address actual = deployment.deployProxy("test", ...);

        // Must match
        assertEq(predicted, actual);
    }
}
```

**Testing:**

```bash
forge test --fork-url $MAINNET_RPC_URL --match-contract DeploymentForkTest
```

### Phase 6: Add Script Tests

**Files:**

- `script/test/AnvilDeploy.s.sol` (new)
- `script/test/ForkedAnvilDeploy.s.sol` (new)

**AnvilDeploy.s.sol:**

```solidity
contract AnvilDeployScript is Script {
  function run() public {
    vm.startBroadcast();

    // Setup mock factory
    MockNicksFactory mockFactory = new MockNicksFactory();

    // Deploy harness
    TestDeployment deployment = new TestDeployment();
    deployment.setMockFactory(address(mockFactory));

    // Deploy system
    deployment.start(msg.sender, "anvil", "v1.0.0", "test-salt");
    address token = deployment.deployMockERC20("token", "Test", "TST");
    deployment.finish();

    console.log("Deployed to raw anvil:");
    console.log("  Token:", token);
    console.log("  Factory:", address(mockFactory));

    vm.stopBroadcast();
  }
}
```

**ForkedAnvilDeploy.s.sol:**

```solidity
contract ForkedAnvilDeployScript is Script {
  function run() public {
    vm.startBroadcast();

    // Verify factory exists
    require(NICKS_FACTORY.code.length > 0, "Must fork mainnet for this script");

    // Deploy harness (no mock needed)
    TestDeployment deployment = new TestDeployment();

    // Deploy system using real factory
    deployment.start(msg.sender, "forked-anvil", "v1.0.0", "test-salt");
    address token = deployment.deployMockERC20("token", "Test", "TST");
    deployment.finish();

    console.log("Deployed to forked anvil:");
    console.log("  Token:", token);
    console.log("  Factory:", NICKS_FACTORY);

    vm.stopBroadcast();
  }
}
```

**Testing:**

```bash
# Raw anvil
anvil &
forge script script/test/AnvilDeploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Forked anvil
anvil --fork-url $MAINNET_RPC_URL &
forge script script/test/ForkedAnvilDeploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Phase 7: Documentation

**Files:**

- `doc/deployment-system.md` - Update factory pattern section
- `test/deployment/README.md` - Add environment-specific examples
- Inline code documentation

**Content:**

- Environment detection explanation
- Setup instructions for each environment
- Examples for each pattern
- Troubleshooting guide

---

## CI/CD Integration

### GitHub Actions Workflow

```yaml
name: Deployment Tests

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run unit tests
        run: forge test --match-path "test/deployment/*.t.sol"

  fork-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run fork tests
        env:
          MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}
        run: |
          forge test \
            --fork-url $MAINNET_RPC_URL \
            --match-contract Fork

  anvil-scripts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Start anvil
        run: anvil &
      - name: Run anvil scripts
        run: |
          forge script script/test/AnvilDeploy.s.sol \
            --rpc-url http://localhost:8545 \
            --broadcast

  forked-anvil-scripts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Start forked anvil
        env:
          MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}
        run: anvil --fork-url $MAINNET_RPC_URL &
      - name: Run forked anvil scripts
        run: |
          forge script script/test/ForkedAnvilDeploy.s.sol \
            --rpc-url http://localhost:8545 \
            --broadcast
```

---

## Benefits by Environment

### Pure Test Environment

✅ Fast iteration (no RPC calls)
✅ No external dependencies
✅ Complete isolation
✅ Perfect for TDD

### Forked Test Environment

✅ Test against real factory
✅ Validate production behavior
✅ Catch integration issues
✅ Still fast (cached fork state)

### Raw Anvil Scripts

✅ Local deployment rehearsal
✅ Debug deployment flows
✅ Test factory setup options
✅ Safe experimentation

### Forked Anvil Scripts

✅ Production-like environment
✅ Test with real chain state
✅ Validate upgrade paths
✅ Final pre-production check

### Production

✅ True cross-chain determinism
✅ Nick's Factory already deployed
✅ Identical addresses across chains
✅ Battle-tested factory

---

## Rollback Strategy

If issues arise during implementation:

1. **Phase 1-2**: Simply revert commits (no breaking changes)
2. **Phase 3+**: Factory abstraction allows fallback to old behavior:
   ```solidity
   function _getCreate3Factory() internal view virtual returns (address) {
     return address(this); // Revert to old behavior
   }
   ```
3. **Full rollback**: Remove factory abstraction, restore direct CREATE3 calls

---

## Open Questions for Review

1. **Factory bytecode storage**: Should we embed real Nick's Factory bytecode for etching in tests/scripts?
2. **Environment detection**: Should we add explicit environment enum or keep auto-detection?
3. **Mock factory variants**: Do we need different mock factories for different test scenarios?
4. **Gas optimization**: Should we cache factory address to save SLOAD operations?
5. **Multi-chain support**: How to handle chains where Nick's Factory isn't deployed?

---

## Success Criteria

- ✅ All existing tests pass without changes
- ✅ Can deploy via mock factory in pure tests
- ✅ Can deploy via real factory on forks
- ✅ Scripts work on raw anvil with mock factory
- ✅ Scripts work on forked anvil with real factory
- ✅ Address predictions match actual deployments in all environments
- ✅ Factory address recorded in registry
- ✅ Documentation covers all environments
- ✅ CI/CD runs all test types
- ✅ Production deployments use real Nick's Factory

---

## Phase 8: Forked Anvil Integration Tests (Planned)

**Goal**: Validate complete deployment workflow in production-like environment with circular dependencies and cross-contract interactions.

**Status**: Implementation planned after all current phases complete and test suite passes.

### Scope

For each mock contract in the test suite, create integration tests that:

1. **Deploy to Forked Anvil**: Execute full deployment on a forked network to simulate mainnet conditions.
2. **Test Circular Dependencies**: Deploy pairs of contracts that reference each other:
   - Use `predictProxyAddress()` to calculate addresses before deployment
   - Pass predicted addresses in constructors or initialize calls
   - Deploy both contracts
   - Execute smoke tests that verify bidirectional interactions work correctly
3. **Smoke Test Coverage**: After deployment, verify:
   - Constructor parameters are set correctly (check immutable values)
   - Initialize parameters are set correctly (check storage values)
   - Cross-contract calls work in both directions
   - Ownership is properly configured
   - Upgrade paths function as expected

### Example Test

```solidity
// Contract A needs address of Contract B in constructor
// Contract B needs address of Contract A in initialize

function test_CircularDependency_ForkedAnvil() public {
  // Predict both addresses before deployment
  address predictedA = deployment.predictProxyAddress("contractA");
  address predictedB = deployment.predictProxyAddress("contractB");

  // Deploy A with B's predicted address in constructor
  ContractAImpl implA = new ContractAImpl(predictedB);
  deployment.deployProxy("contractA", address(implA), abi.encodeCall(ContractA.initialize, (owner)));

  // Deploy B with A's predicted address in initialize
  ContractBImpl implB = new ContractBImpl();
  deployment.deployProxy("contractB", address(implB), abi.encodeCall(ContractB.initialize, (predictedA, owner)));

  // Smoke tests: verify bidirectional calls work
  ContractA contractA = ContractA(predictedA);
  ContractB contractB = ContractB(predictedB);

  assertEq(contractA.getPartner(), predictedB, "A should reference B");
  assertEq(contractB.getPartner(), predictedA, "B should reference A");

  // Test actual interaction
  contractA.callPartner(); // Should succeed calling B
  contractB.callPartner(); // Should succeed calling A
}
```

### Implementation Notes

- These tests validate the entire deployment system works in production-like conditions
- Circular dependency support is a key feature enabled by deterministic address prediction
- Smoke tests ensure deployed contracts are functional, not just present at correct addresses
- Run after current test suite passes to ensure foundational functionality is solid

### Test Location

Create new file: `test/deployment/DeploymentForkedAnvil.t.sol`

### Benefits

- Validates end-to-end production deployment flow
- Catches integration issues before mainnet deployment
- Provides confidence in circular dependency handling
- Serves as documentation for complex deployment patterns
