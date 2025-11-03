# Deployment System Design

## Purpose

- Support BaoOwnable's ownership pattern with front-running protection during proxy initialization.
- Provide deterministic proxy addresses across chains using CREATE3.
- Enable incremental deployments with state preservation via JSON serialization.
- Support chain-wide pausing via dedicated Pause contract.
- Maintain typesafe deployment workflow shared by Foundry and Wake.

## Cross-Chain Determinism Strategy

The deployment system achieves deterministic addresses across chains through **injected deployer context** combined with CREATE3:

### Why CREATE3 and Nick's Factory?

**CREATE3** provides bytecode-independent deterministic addresses depending only on deployer and salt. This enables predicting all proxy addresses before deployment, eliminating order dependencies and enabling circular references.

**Nick's Factory** (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) deploys the harness deterministically via CREATE2, enabling identical contract addresses across chains. While deployed on 100+ chains, new chains may require manual deployment—see [deployment instructions](https://github.com/Arachnid/deterministic-deployment-proxy#usage).

**Result**: Order-independent deployment of complex multi-contract systems with identical predictable cross-chain addresses.

### Architecture

- **Deployer Context Injection**: The `Deployment` contract accepts a `deployerContext` address in its constructor. This address is used by CREATE3 for all address calculations, enabling the same deployment code to work identically in production and test environments.
- **CREATE3 Layer**: The harness uses CREATE3 (via Solady) to deploy proxies. CREATE3 derives addresses solely from the deployer context and salt, independent of bytecode. This means identical salts with the same deployer context produce identical contract addresses across all chains.

### Production Deployment

1. **Deploy Harness via Nick's Factory**: Use Nick's Factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) to deploy your harness contract with a fixed salt (e.g., `keccak256("bao-deployment-harness-v1")`). Nick's Factory exists on 100+ chains and uses CREATE2 for deterministic deployment.
2. **Predict Harness Address**: Calculate the harness address using CREATE2 formula: `keccak256(0xff ++ factory ++ salt ++ keccak256(bytecode))`.
3. **Instantiate Harness**: Create the harness passing the predicted address as `deployerContext`: `new MyDeployment(predictedAddress)`.
4. **Deploy Contracts**: Use the harness to deploy proxies and implementations. All addresses will be deterministic based on the deployer context.
5. **Repeat on All Chains**: Deploy the harness at the same address on each chain (using the same salt with Nick's Factory), then deploy contracts using identical `systemSaltString` values.

**Result**: Identical contract addresses across all chains.

### Development and Testing

Two approaches available depending on testing goals:

#### Simple Approach (Recommended for Most Tests)

- **Pass `address(0)`**: Instantiate deployment with `new TestDeployment()` which passes `address(0)` to the base constructor.
- **Default Behavior**: When `deployerContext` is `address(0)`, the constructor defaults to `address(this)`.
- **Benefits**: Simple, fast iteration, no extra setup required.
- **Limitation**: Deployed addresses won't match production addresses (but will be deterministic within test environment).

#### Full Production Simulation (For Integration Tests)

- **Deploy Mock Factory**: Use `MockNicksFactory` and `vm.etch()` to place it at the real Nick's Factory address.
- **Deploy Harness via Factory**: Deploy your harness through the mock factory exactly as production would.
- **Use Production Code**: The harness will behave identically to production, enabling full end-to-end validation.
- **Benefits**: Validates the complete production flow including factory interaction and address predictions.

```solidity
// Example: Full production simulation in tests
function setUp() public {
  // Deploy and etch mock factory at Nick's address
  MockNicksFactory mockFactory = new MockNicksFactory();
  vm.etch(NICKS_FACTORY, address(mockFactory).code);

  // Deploy harness via factory (same as production)
  bytes32 salt = keccak256("bao-deployment-harness-v1");
  bytes memory deployData = abi.encodePacked(salt, type(MyDeployment).creationCode);
  (bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
  address harnessAddr = address(uint160(uint256(bytes32(returnData))));

  // Now create harness with its own address as context
  deployment = MyDeployment(harnessAddr);
}
```

## Salt Structure

The deployment system uses two levels of salts to achieve deterministic addresses:

- **System Salt**: Contains system-wide identifiers (e.g., for a Harbor system: names of pegged and collateral tokens, plus other system-pertinent information). Set once per deployment via `startDeployment()` or `resumeDeployment()`.
- **Proxy Salt**: Contains the contract-specific name (e.g., "minter", "stability_pool_collateral"). Combined with system salt to form the complete salt: `<systemSaltString>/<proxyKey>/UUPS/proxy`.

**Result**: Identical system salt + proxy key = identical addresses across chains, while different systems (e.g., different token pairs) get different addresses.

## Constructor vs Initialize Design Pattern

Implementations follow a specific pattern for parameter handling:

- **Constructor Parameters**: For values that should not change or won't change often. These require a proxy upgrade to modify.

  - Examples: Token addresses, immutable configuration
  - Benefit: Do not consume contract code size, saving deployment gas
  - Set when creating the implementation: `new MockMinter(collateralToken, peggedToken, leveragedToken)`

- **Initialize Parameters**: For values we may want to change frequently via update functions.
  - Examples: Oracle addresses, fee rates, operational parameters
  - Pattern: If update functions exist for these values, they're NOT included in initialize. Instead, the deployer sets them via the update functions after initialization.
  - Set when deploying the proxy: `abi.encodeCall(MockMinter.initialize, (oracle, owner))`

**Constructor parameters are preferred** where possible because they minimize contract code size and gas costs.

## Core Components

- **Bootstrap Stub Pattern**

  Implementation artifact required because CREATE3 makes `msg.sender = proxy` during deployment, but BaoOwnable's `_initializeOwner()` uses `msg.sender` to set owner. Each session deploys one `UUPSProxyDeployStub` owned by the harness. Proxies deploy via CREATE3 as `ERC1967Proxy` pointing to the stub, then upgrade to implementation with `upgradeToAndCall(implementation, initData)`. This ensures the harness is `msg.sender` during initialization, enabling BaoOwnable compatibility with CREATE3.

  _Future direction_: BaoOwnable will be refactored to accept an explicit owner parameter, eliminating this requirement and aligning with industry-standard single-step ERC1967Proxy deployment.

- **Deployment Registry + Metadata**

  Stores registry entries, proxy metadata, system salt string, owner address, and deployment state. JSON serialization captures full state for deterministic resumption with versioning.

- **Deployment Facade**

  Provides two mutually exclusive entry points: `start()` for fresh sessions, `resume()` for sessions restored from JSON. Tracks lifecycle: `Uninitialized → Active → Finished`; re-running start/resume after activation reverts.

## Access Control Model

- **Proxy Ownership**

  Harness becomes temporary owner, completes configuration, then transfers to multisig via `finish()`. BaoOwnable's two-step transfer (set pending, confirm) provides safety for ownership handoff.

- **Initialization Security**

  Proxy deploys to deterministic address via CREATE3, then upgrades with initialization atomically via `upgradeToAndCall`. This prevents front-running while maintaining determinism.

## Deployment Workflow

- **Fresh Deployment (`start`)**
  1. Accepts owner, network, version, and system salt string.
  2. Deploys bootstrap stub owned by the harness.
  3. Persists metadata enabling deterministic proxy addresses.
- **Resumed Deployment (`resume`)**
  1. Loads JSON (from system salt or custom path).
  2. Deploys new bootstrap stub for this session.
  3. Continues deploying with restored parameters.
- **Incremental Phases**

  Each phase resumes from JSON, deploys additional proxies, saves JSON. Address determinism flows from salt scheme, not runtime state.

- **Finish (`finish`)**

  Transfers proxy ownership from harness to configured owner. Skips proxies restored from JSON (already transferred). Returns count of transferred proxies.

## Deterministic Proxy Guarantees

- Addresses derived from salt `<systemSaltString>/<proxyKey>/UUPS/proxy`, persisted in JSON for deterministic resumption.
- Predictive checks validate deployed addresses match predictions.
- Bootstrap pattern prevents front-running while maintaining determinism.
- Known addresses up-front enable order-independent deployment and circular dependencies.

## Testing Coverage

### Current Mapping

| Requirement               | Test (file :: contract :: function)                                                                                           | Notes                                                                       |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Bootstrap pattern         | `test/deployment/DeploymentProxy.t.sol :: DeploymentProxyTest :: test_DeployProxy`                                            | Validates proxy deployment and upgrade-with-initialization flow.            |
| Lifecycle enforcement     | `test/deployment/DeploymentBasic.t.sol :: DeploymentBasicTest :: test_Initialize`, `test_Finish`                              | Covers `start`/`resume` lifecycle and finish behavior.                      |
| Deterministic predictions | `test/deployment/DeploymentProxy.t.sol :: DeploymentProxyTest :: test_PredictProxyAddress`, `test_ResumeRestoresPredictions_` | Ensures predictions survive JSON resumptions with deterministic salts.      |
| Registry serialization    | `test/deployment/DeploymentJson.t.sol :: DeploymentJsonTest :: test_LoadFromJson`, `test_SaveToJson` variants                 | Confirms contracts, proxies, libraries, and parameters survive round-trips. |
| Incremental phases        | `test/deployment/DeploymentIntegration.t.sol :: DeploymentIntegrationTest :: test_IncrementalDeployment`                      | Simulates phased rollouts with repeated JSON loads.                         |
| Production upgrade flows  | `test/deployment/DeploymentUpgrade.t.sol :: DeploymentUpgradeTest :: test_UpgradeWithStateTransition` et al.                  | Validates upgrade sequencing and state retention.                           |

### Coverage Gaps

- Pause contract lifecycle (upgrade to `Pause` then resume) remains untested; requires concrete Pause implementation.
- Cross-deployer "cross-chain" equivalence scenarios that compare predictions across independent harness instances still need an explicit regression beyond JSON resumptions.
- Tests currently use `TestDeployment` with `address(0)` defaulting to `address(this)`. Full production simulation using `MockNicksFactory` via `vm.etch()` is not yet implemented in test suite.

## Rejected Alternatives

- **Timeout-Based Deployer Revocation**: Fragile deployment duration assumptions can strand upgrades.
- **Single-Step ERC1967Proxy Deployment**: Industry standard pattern calls `upgradeToAndCall(implementation, _data)` in constructor. CREATE3 makes `msg.sender = proxy`, which breaks BaoOwnable's use of `msg.sender` for ownership. Bootstrap stub adds one transaction per proxy but enables BaoOwnable + CREATE3 compatibility.
- **Safe Singleton Factory**: Nick's Factory exists on more chains than Safe Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`).
- **Keyless Deployment for Harness**: Generating one-time keypairs adds operational complexity. Nick's Factory achieves the same outcome with simpler tooling.
- **Same-Nonce EOA Deployment**: Fragile; a single out-of-order transaction on any chain breaks determinism. Factory-based deployment is more robust.
- **Environment Auto-Detection**: Using chain ID or block number introduces hidden behavior and potential misconfiguration. Explicit deployer context injection makes deployment mode clear.
- **Separate Test/Production Harnesses**: Maintaining different code paths creates drift. Injected deployer context allows identical code in both environments with a simple constructor parameter switch.

## Usage Guide

### Production Deployment Workflow

1.  **Predict Harness Address**:
    - Calculate where the harness will be deployed using Nick's Factory and your chosen salt.
    - Formula: `address = keccak256(0xff ++ NICKS_FACTORY ++ salt ++ keccak256(bytecode)) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF`.
2.  **Deploy Harness via Nick's Factory** (one-time per chain):
    - Use Nick's Factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C` with a fixed salt.
    - Deploy with: `NICKS_FACTORY.call(abi.encodePacked(salt, type(YourDeployment).creationCode))`.
    - Verify the deployed address matches the prediction.
3.  **Instantiate Harness with Context**:
    - Create deployment instance: `deployment = YourDeployment(deployedAddress)`.
    - The harness is constructed with its own address as the `deployerContext`.
4.  **Deploy Pause Contract**: Deploy the dedicated `Pause` contract owned by the multisig for emergency upgrades.
5.  **Start Deployment**: Call `start()` with owner, network, version, and system salt string. Use identical `systemSaltString` across chains for matching addresses.
6.  **Deploy Proxies**: Each call deploys proxy to deterministic address via CREATE3, then calls `upgradeToAndCall(implementation, initData)`.
7.  **Pause Contracts**: To pause a contract, upgrade proxy to `Pause` contract; restore production implementation when safe.
8.  **Finalize**: Invoke `finish()` to transfer proxy ownership to configured owner, then save JSON.
9.  **Repeat on Other Chains**: Use same salt with Nick's Factory to deploy harness at same address on each chain, then repeat steps 3-8.

### Development and Testing Workflow

#### Simple Testing (Current Implementation)

1.  **Instantiate Harness**: `deployment = new TestDeployment()` (defaults to `address(this)` as deployer context).
2.  **Start Deployment**: Call `start()` with test parameters.
3.  **Deploy Contracts**: Each proxy deploys via CREATE3 with bootstrap pattern.
4.  **Save State**: Serialize to JSON for verification and incremental testing.

#### Full Production Simulation (Planned)

1.  **Mock Nick's Factory**: Deploy `MockNicksFactory` and use `vm.etch(NICKS_FACTORY, mockFactory.code)`.
2.  **Deploy Harness via Mock Factory**: Follow production workflow steps 1-3 using the mock factory.
3.  **Run Production Code**: Execute the exact same deployment logic as production would use.
4.  **Validate Addresses**: Confirm predicted addresses match deployed addresses.
5.  **Note**: This approach is not yet implemented in the test suite but is supported by the architecture.

- **Incremental / Resumed Deployment**
  1. Call `resume` with system salt string (to derive filepath) or custom filepath.
  2. Harness restores registry state and deploys new bootstrap stub for this session.
  3. Deploy additional contracts as needed; they use same deterministic addresses.
  4. After completing phase, call `finish()` to transfer new proxy ownership, then save JSON.
- **Governance Changes**
  - Proxies point directly to implementations from the moment of deployment.
  - Production contracts follow the Bao ownership choreography: the deployer configures the implementation, then hands control to the multisig once it is safe.
  - Emergency upgrades reuse the same deterministic salt scheme so addresses remain predictable regardless of operator.

## Pausing Model

- A dedicated `Pause` contract is deployed once and owned permanently by the system multisig.
- Pausing a proxy is achieved by upgrading the proxy to delegate to `Pause`; the inherited fallback reverts all calls, halting contract behavior.
- Resuming service upgrades the proxy back to the previous (or patched) implementation using the same set → upgrade → rotate-away choreography.

## Lifecycle Clarifications

- `start()` is typically invoked once to seed system salt and metadata. All subsequent activity uses `resume()` to extend the deterministic state. Each session creates its own bootstrap stub. The same contracts underpin both Foundry and Wake workflows.

## Existing Deployments

- Every persisted deployment JSON must include owner, system salt string, metadata timestamps, and deterministic proxy records. Resuming a deployment without these fields is unsupported and will revert.
