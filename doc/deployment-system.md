# Deployment System Design

## Purpose

- Provide a defense-in-depth bootstrap that keeps UUPS proxies inert until an approved implementation is installed.
- Guarantee deterministic proxy addresses across chains and incremental phases.
- Coordinate upgrades while keeping proxy addresses deterministic and preserving downstream multisig ownership flows.
- Deliver a chain-wide pausing facility that routes halted proxies through a dedicated Pause contract with the owner baked into the bytecode.
- Maintain a typesafe, linted, and fully tested deployment workflow that is shared by Foundry and Wake automation.

## Cross-Chain Determinism Strategy

The deployment system achieves deterministic addresses across chains through **injected deployer context** combined with CREATE3:

### Architecture

- **Deployer Context Injection**: The `Deployment` contract accepts a `deployerContext` address in its constructor. This address is used by CREATE3 for all address calculations, enabling the same deployment code to work identically in production and test environments.
- **CREATE3 Layer**: The harness uses CREATE3 (via Solady) to deploy proxies and stubs. CREATE3 derives addresses solely from the deployer context and salt, independent of bytecode. This means identical salts with the same deployer context produce identical contract addresses across all chains.

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

## Core Components

- **UUPSProxyDeployStub**
  - One stub per proxy; each stub address is derived deterministically from the proxy's logical salt using CREATE3.
  - Pins the deployment harness as the immutable owner at construction; no additional roles exist.
  - Exposes only `upgradeTo` / `upgradeToAndCall`, letting the owner install the production implementation.
  - Exists purely for bootstrap—after the first upgrade the proxy delegates elsewhere and the stub stays idle.
- **Deployment Registry + Metadata**
  - Stores registry entries, proxy metadata, system salt string, per-proxy stub addresses, owner address, and the current deployment state.
  - Serialization to JSON captures the full state required to resume deployments deterministically, with versioning.
- **Deployment Facade**
  - Provides two mutually exclusive entry points:
    1. `startDeployment(...)` for fresh sessions.
    2. `resumeDeployment(...)` for sessions restored from JSON.
  - Tracks lifecycle: `Uninitialized → Active → Finished`; any attempt to re-run a start/resume method after activation reverts.

## Access Control Model

- **Stub Owner**
  - Each stub stores the deploying harness as an immutable owner when constructed via CREATE3.
  - Only that owner can invoke the initial upgrade into the target implementation; there are no backup roles.
  - Once the proxy upgrades, control passes to the implementation and the stub’s ownership no longer matters.
- **Production Implementations**
  - Continue to use the Bao deployer-initiated ownership flow so deployers complete configuration and role grants before the irreversible-without-an-upgrade transfer to the multisig, keeping initializer logic lean and gas efficient.

## Deployment Workflow

- **Fresh Deployment (`startDeployment`)**
  1. Require lifecycle state `Uninitialized`.
  2. Accept explicit inputs: system salt string and owner address.
  3. Persist metadata (owner, system salt string) and mark lifecycle `Active` so subsequent proxy deployments can derive deterministic stub and proxy addresses from the agreed salt.
- **Resumed Deployment (`resumeDeployment`)**
  1. Require lifecycle state `Uninitialized`.
  2. Load JSON, restore metadata (owner, system salt string, prior deployments, predicted proxy and stub addresses).
  3. Mark lifecycle `Active` and continue deploying with the restored parameters.
- **Incremental Phases**
  - Each phase loads JSON, deploys additional stubs and proxies, and saves JSON.
  - Phases do not depend on prior runtime state; address determinism flows solely from the salt scheme.
- **Finish (`finishDeployment`)**
  - Calls `finalizeOwnership` internally before marking lifecycle `Finished`.
  - Updates metadata timestamps and confirms no further stubs remain pending.

## Deterministic Proxy Guarantees

- Predictive checks run before and after each CREATE3 deployment to ensure the stored prediction matches the actual address.
- Deterministic addresses come from deriving two salts per logical deployment identifier `salt`: `<salt>/stub` for the stub and `<salt>/proxy` for the proxy. Both values are persisted in JSON so resumptions can replay the exact sequence.
- Bootstrap safety hinges on two constraints: outsiders must never reach `initialize`, and the stub address must be derived solely from the agreed salt.
- To satisfy both constraints we deploy a dedicated, minimal `UUPSProxyDeployStub` per proxy. The harness installs the stub, deploys the proxy that initially delegates to it, and immediately upgrades through the stub into the production implementation. After that upgrade the stub is never touched again, but its address remains part of the deterministic record.

## Testing Coverage

### Current Mapping

| Requirement               | Test (file :: contract :: function)                                                                                               | Notes                                                                                    |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Stub role management      | `test/deployment/UUPSProxyDeployStub.t.sol :: UUPSProxyDeployStubTest :: test_AuthorizeUpgradeRequiresOwner_`                     | Planned update: assert only the stub owner (BaoOwnable) may authorize the first upgrade. |
| Ownership handover        | `test/deployment/UUPSProxyDeployStub.t.sol :: UUPSProxyDeployStubTest :: test_OwnershipTransfer_`                                 | Planned update: lean BaoOwnable_v2 semantics, no two-step window.                        |
| Lifecycle enforcement     | `test/deployment/DeploymentBasic.t.sol :: DeploymentBasicTest :: test_StartDeployment_`, `test_RevertWhen_ActionWithoutLifecycle` | Covers exclusivity of `start`/`resume` and finish guard rails.                           |
| Deterministic predictions | `test/deployment/DeploymentProxy.t.sol :: DeploymentProxyTest :: test_PredictProxyAddress`, `test_ResumeRestoresPredictions_`     | Ensures predictions survive JSON resumptions with per-proxy stub salts.                  |
| Registry serialization    | `test/deployment/DeploymentJson.t.sol :: DeploymentJsonTest :: test_LoadFromJson`, `test_SaveToJson` variants                     | Confirms contracts, proxies, libraries, and parameters survive round-trips.              |
| Stub metadata validation  | `test/deployment/DeploymentJson.t.sol :: DeploymentJsonTest :: test_FromJsonRevertWhenStubMissing_`                               | Guards against missing stub metadata during resume.                                      |
| Incremental phases        | `test/deployment/DeploymentIntegration.t.sol :: DeploymentIntegrationTest :: test_IncrementalDeployment`                          | Simulates phased rollouts with repeated JSON loads.                                      |
| Production upgrade flows  | `test/deployment/DeploymentUpgrade.t.sol :: DeploymentUpgradeTest :: test_UpgradeWithStateTransition` et al.                      | Validates upgrade sequencing and state retention.                                        |

### Coverage Gaps

- Pause contract lifecycle (upgrade to `Pause` then resume) remains untested; requires concrete Pause implementation.
- Cross-deployer "cross-chain" equivalence scenarios that compare predictions across independent harness instances still need an explicit regression beyond JSON resumptions.
- Need a regression that proves stubs are removed from the execution path after the first upgrade (e.g., subsequent calls route to the implementation, not the stub).

## Rejected Alternatives

- **Timeout-Based Deployer Revocation**: Rejected in favor of explicit owner-driven rotation because timeouts introduce fragile assumptions about deployment duration and can strand upgrades mid-phase.
- **Single Shared Stub Per Chain**: Rejected because keeping one permanent stub would either leak its upgrade state into every proxy (via delegatecall storage) or require the stub itself to become upgradeable, undermining the deterministic bootstrap guarantees.
- **OpenZeppelin UUPS Stub**: Rejected because the minimal OZ pattern still bundles modifier checks, `_authorizeUpgrade` hooks, and event emissions that bloat bytecode and gas. `forge inspect` shows the OZ stub shipping a 4,350 byte runtime (870,000 gas) and a 4,454 byte init payload. Assuming half of the init bytes are zero (4 gas) and half non-zero (16 gas) yields another 44,540 gas for creation calldata, so the total deployment lands at ~914,540 gas ($91.45 at $0.10 / 1k gas). Our bespoke stub compiles down to a 1,828 byte runtime (365,600 gas) and a 2,295 byte init payload (~22,950 gas), for an all-in cost near 388,550 gas ($38.86). The delta is roughly 525,990 gas or $52.60 per proxy. We achieve that by baking the owner directly into the constructor-time storage and trimming the surface to guarded `upgradeTo*` calls.
- **Proxy-Level Access Controls**: Rejected to avoid storage collisions with production implementations; all deployer management remains in the stub.
- **Safe Singleton Factory**: While battle-tested and widely deployed (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`), Nick's Factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) is more universal and exists on more chains. Both provide equivalent CREATE2 determinism for harness deployment; Nick's Factory is preferred for broader compatibility.
- **Keyless Deployment for Harness**: Generating one-time keypairs and broadcasting signed transactions provides maximum trustlessness but adds operational complexity. Nick's Factory achieves the same outcome (deterministic harness addresses) with simpler tooling and no manual key management.
- **Same-Nonce EOA Deployment**: Deploying the harness from an EOA at the same nonce across chains is fragile; a single out-of-order transaction on any chain breaks determinism. Factory-based deployment via Nick's method is more robust.
- **Environment Auto-Detection**: Using chain ID or block number to automatically switch between test and production modes introduces hidden behavior and potential for misconfiguration. Explicit deployer context injection makes the deployment mode clear and predictable.
- **Separate Test/Production Harnesses**: Maintaining different code paths for test and production environments creates drift and reduces test coverage of production code. Injected deployer context allows identical code to run in both environments with a simple constructor parameter switch.

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
4.  **Deploy Pause Contract**: Deploy the dedicated `Pause` contract owned by the multisig so it is available for emergency upgrades.
5.  **Initialize Deployment**: Call `startDeployment` with the owner and system salt string. Use the same `systemSaltString` on all chains to ensure identical contract addresses.
6.  **Deploy Proxies**: Execute proxy deployments; each call deterministically deploys a matching stub at `<salt>/stub`, installs the proxy at `<salt>/proxy`, and immediately upgrades through that stub into the target implementation. To pause a contract, upgrade the proxy to the `Pause` contract and later restore the production implementation when safe.
7.  **Finalize**: Invoke `finishDeployment` (which finalizes proxy ownership) and save JSON.
8.  **Repeat on Other Chains**: Use the same salt with Nick's Factory to deploy the harness at the same address on each chain, then repeat steps 3-7.

### Development and Testing Workflow

#### Simple Testing (Recommended)

1.  **Instantiate Harness**: `deployment = new TestDeployment()` (passes `address(0)`, defaults to `address(this)`).
2.  **Initialize Deployment**: Call `startDeployment` with test parameters and a consistent `systemSaltString`.
3.  **Deploy Contracts**: Use the harness to deploy proxies and implementations; CREATE3 ensures determinism within test environment.
4.  **Save State**: Serialize to JSON for cross-test verification and incremental testing.

#### Full Production Simulation (For Integration Tests)

1.  **Mock Nick's Factory**: Deploy `MockNicksFactory` and use `vm.etch(NICKS_FACTORY, mockFactory.code)`.
2.  **Deploy Harness via Mock Factory**: Follow production workflow steps 1-3 using the mock factory.
3.  **Run Production Code**: Execute the exact same deployment logic as production would use.
4.  **Validate Addresses**: Confirm predicted addresses match deployed addresses.

- **Incremental / Resumed Deployment**
  1. Call `resumeDeployment` with the saved JSON.
  2. The harness restores registry state, redeploys any required stubs deterministically, and resumes deployments.
  3. After completing the phase, call `finishDeployment` (or re-save JSON if continuing later).
- **Governance Changes**
  - Stubs do not participate in ongoing governance; they exist only for the first upgrade into the production implementation.
  - Production contracts still follow the Bao ownership choreography: the deployer configures the implementation, then hands control to the multisig once it is safe.
  - Emergency upgrades reuse the same deterministic salt scheme so addresses remain predictable regardless of operator.

## Pausing Model

- A dedicated `Pause` contract is deployed once and owned permanently by the system multisig.
- Pausing a proxy is achieved by upgrading the proxy to delegate to `Pause`; the inherited fallback reverts all calls, halting contract behavior.
- Resuming service upgrades the proxy back to the previous (or patched) implementation using the same set → upgrade → rotate-away choreography.

## Lifecycle Clarifications

- Every system depends on the canonical system salt, the `Pause` target, and the per-proxy stub addresses recorded in JSON. `startDeployment` is typically invoked only once—when seeding those anchors and the initial metadata. `Pause` may be replaced (and persisted) without rerunning `startDeployment`; the shared JSON keeps deterministic predictions aligned. All subsequent activity, including incremental feature rollout or emergency response, uses `resumeDeployment` so new layers extend the existing deterministic state instead of recreating it. The same contracts underpin both Foundry and Wake workflows to guarantee environment parity.

## Existing Deployments

- Every persisted deployment JSON must include stub addresses, owner, system salt string, metadata timestamps, and deterministic proxy records. Resuming a deployment without these fields is unsupported and will revert.
