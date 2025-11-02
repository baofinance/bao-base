# Deployment Context Injection - Quick Reference

## Overview

The deployment system uses **injected deployer context** to achieve identical contract addresses across chains while using the same code in production and tests.

## How It Works

- **CREATE3** calculates addresses as: `hash(deployer, salt)`
- The `deployer` is the **DEPLOYER_CONTEXT** passed to the `Deployment` constructor
- Same context + same salt = same addresses across all chains

## Production Usage

### Step 1: Deploy Harness via Nick's Factory

```solidity
// Nick's Factory address (exists on 100+ chains)
address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
bytes32 constant SALT = keccak256("your-protocol-harness-v1");

// Predict address
bytes memory bytecode = type(YourDeployment).creationCode;
bytes32 hash = keccak256(abi.encodePacked(
    bytes1(0xff),
    NICKS_FACTORY,
    SALT,
    keccak256(bytecode)
));
address predicted = address(uint160(uint256(hash)));

// Deploy (do this on each chain)
bytes memory deployData = abi.encodePacked(SALT, bytecode);
(bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
address deployed = address(uint160(uint256(bytes32(returnData))));
```

### Step 2: Create Your Deployment Contract

```solidity
contract YourDeployment is DeploymentFoundry {
  constructor(address deployerContext) DeploymentFoundry(vm, deployerContext) {}

  function deployProtocol() external {
    startDeployment(owner, "mainnet", "v1.0.0", "protocol-salt");

    // Deploy proxies - addresses will be deterministic
    deployProxy("token", "TokenImpl", initData);
    deployProxy("vault", "VaultImpl", initData);

    finishDeployment();
    saveToJson("deployments/mainnet.json");
  }
}
```

### Step 3: Run Deployment

```solidity
// On each chain:
// 1. Harness is already at same address (deployed via Nick's Factory)
// 2. Instantiate and run
YourDeployment deployment = YourDeployment(harnessAddress);
deployment.deployProtocol();
```

## Test Usage

### Simple Testing (Recommended)

```solidity
contract TestDeployment is Deployment {
  constructor() Deployment(address(0)) {} // Defaults to address(this)
}

function setUp() public {
  deployment = new TestDeployment();
  deployment.startDeployment(address(this), "test", "v1", "test-salt");
}
```

### Full Production Simulation

```solidity
import { MockNicksFactory } from "test/mocks/deployment/MockNicksFactory.sol";

function setUp() public {
  // Mock Nick's Factory
  MockNicksFactory mockFactory = new MockNicksFactory();
  vm.etch(NICKS_FACTORY, address(mockFactory).code);

  // Deploy harness via mock factory (same as production)
  bytes memory deployData = abi.encodePacked(SALT, type(YourDeployment).creationCode);
  (bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
  address harnessAddr = address(uint160(uint256(bytes32(returnData))));

  // Use deployed harness
  deployment = YourDeployment(harnessAddr);
}
```

## Key Benefits

✅ **Identical code** runs in production and tests
✅ **Simple switch**: just the constructor parameter
✅ **Predictable addresses**: calculate before deploying
✅ **Cross-chain determinism**: same salt = same addresses
✅ **No environment detection**: explicit, not magic

## See Also

- Full documentation: [deployment-system.md](./deployment-system.md)
- Example script: [ExampleProductionDeployment.s.sol](../script/examples/ExampleProductionDeployment.s.sol)
- Mock factory: [MockNicksFactory.sol](../test/mocks/deployment/MockNicksFactory.sol)
