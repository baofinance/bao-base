# Deployment System Design

## Purpose

- Provide a defense-in-depth bootstrap ("stem") that keeps UUPS proxies inert until an approved implementation is installed.
- Guarantee deterministic proxy addresses across chains and incremental phases.
- Enable controlled deployer rotation without forfeiting upgrade authority or compromising proxy determinism.
- Deliver a chain-wide pausing facility that routes halted proxies through a dedicated Pause contract with the owner baked into the bytecode.
- Maintain a typesafe, linted, and fully tested deployment workflow that is shared by Foundry and Wake automation.

## Core Components

- **UUPSProxyDeployStub**
  - Single instance per chain; address is part of the CREATE3 deterministic input.
  - Keeps a single deployer address alongside the controlling multisig owner.
  - Defaults the deployer to the stub deployer and exposes `setDeployer` so the owner can rotate that role ahead of an upgrade.
  - Relies on OpenZeppelin's UUPS upgrade hooks and Solady's two-step ownership handover (with a 48-hour acceptance window) so governance migrates safely without redeploying the stub.
- **Deployment Registry + Metadata**
  - Stores registry entries, proxy metadata, system salt string, stub address, owner address, active deployer identities, and the current deployment state.
  - Serialization to JSON captures the full state required to resume deployments deterministically.
- **Deployment Facade**
  - Provides two mutually exclusive entry points:
    1. `startDeployment(...)` for fresh sessions.
    2. `resumeDeployment(...)` for sessions restored from JSON.
  - Tracks lifecycle: `Uninitialized → Active → Finished`; any attempt to re-run a start/resume method after activation reverts.

## Access Control Model

- **Owner (Multisig)**
  - Controls the stub through Solady's two-step handover and is the only party allowed to rotate the deployer.
  - Can immediately reclaim deployer authority after an upgrade by setting the deployer back to a safe address.
- **Deployer**
  - Single active address stored on the stub; defaults to the account that deployed it.
  - Rotated via `setDeployer` whenever a new operator should run upgrades, avoiding timeout assumptions entirely.
  - JSON serialization records each session's deployer for auditability.
- **Production Implementations**
  - Use the Bao deployer-initiated ownership flow so deployers complete configuration and role grants before the irreversible-without-an-upgrade transfer to the multisig, keeping initializer logic lean and gas efficient.

## Deployment Workflow

- **Fresh Deployment (`startDeployment`)**
  1. Require lifecycle state `Uninitialized`.
  2. Accept explicit inputs: stub address, system salt string, owner address, optional initial deployer address.
  3. Verify stub ownership and set the deployer on-chain.
  4. Persist metadata and mark lifecycle `Active`.
- **Resumed Deployment (`resumeDeployment`)**
  1. Require lifecycle state `Uninitialized`.
  2. Load JSON, restore metadata (stub, salt, owner, prior deployments, predicted addresses).
  3. Rotate the deployer if needed before further proxy deployments; this unlocks layered upgrades where new modules or implementations are added in subsequent phases.
  4. Mark lifecycle `Active`.
- **Incremental Phases**
  - Each phase loads JSON, sets the current deployer, performs deployments, saves JSON.
  - Phases do not depend on previous deployer keys; address determinism flows from stub + salt.
- **Finish (`finishDeployment`)**
  - Calls `finalizeOwnership` internally before marking lifecycle `Finished`.
  - Rotates the deployer back if required and updates metadata timestamps.

## Deterministic Proxy Guarantees

- Predictive checks run before and after each CREATE3 deployment to ensure the stored prediction matches the actual address.
- Stub address and system salt string are immutable inputs to address derivation and must be provided (or restored) before any proxy deployment.
- JSON persistence records both predicted and realized proxy addresses to detect drift when resuming.

## Testing Coverage

- **Unit Tests**
  - Stub role management: deployer rotation, owner transfer, unauthorized upgrades revert.
  - Lifecycle enforcement: `startDeployment` and `resumeDeployment` exclusivity, `finishDeployment` idempotency.
  - Prediction accuracy: `predictProxyAddress` equals actual deployment address.
- **Integration Tests**
  - Incremental deployment phases with different deployer rotations; verifies deterministic addresses and successful upgrades.
  - Cross-chain equivalence simulated via repeated runs with distinct deployer accounts but fixed stub + salt.
  - Finish flow ensures ownership transfers before metadata finalization.
  - Layered resumptions that attach additional contracts or upgrade implementations after loading from JSON.
  - Pause / resume lifecycle that upgrades proxies to the Pause contract and back, confirming authorization and determinism remain intact.

## Rejected Alternatives

- **Timeout-Based Deployer Revocation**: Rejected in favor of explicit owner-driven rotation because timeouts introduce fragile assumptions about deployment duration and can strand upgrades mid-phase.
- **Per-Proxy Stub Deployments**: Rejected because each stub address alters CREATE3 outcomes; a single shared stub per chain is mandatory.
- **Proxy-Level Access Controls**: Rejected to avoid storage collisions with production implementations; all deployer management remains in the stub.

## Usage Guide

- **Initial Set-Up**

1.  Deploy the single-chain `UUPSProxyDeployStub` and initialize it with the multisig owner. Deploy the dedicated `Pause` contract owned by the same multisig so it is available for emergency upgrades.
2.  Call `startDeployment` with stub address, owner, system salt string, and an optional initial deployer address.
3.  Execute proxy deployments; each call checks deterministic predictions automatically. To pause a contract, rotate the deployer if needed and upgrade the proxy to the `Pause` contract; resume by upgrading back to the prior implementation when safe.
4.  Invoke `finishDeployment` (which finalizes proxy ownership) and save JSON.

- **Incremental / Resumed Deployment**
  1. Call `resumeDeployment` with the saved JSON and the new deployer identity.
  2. The harness restores registry state, sets the deployer on-chain via the stub, and resumes deployments.
  3. After completing the phase, call `finishDeployment` (or re-save JSON if continuing later).
- **Governance Changes**
  - The multisig owner manages handovers through Solady's request → complete flow on the stub to migrate governance.
  - Owner sets the deployer before starting an upgrade session and can immediately rotate back once complete.
  - Upgrades follow a consistent flow: owner sets the deployer, the deployer performs `upgradeTo` / `upgradeToAndCall` via the stub-governed proxy, and the owner rotates the deployer away when finished.

## Pausing Model

- A dedicated `Pause` contract is deployed once and owned permanently by the system multisig.
- Pausing a proxy is achieved by setting the deployer and upgrading the proxy to delegate to `Pause`; the inherited fallback reverts all calls, halting contract behavior.
- Resuming service upgrades the proxy back to the previous (or patched) implementation using the same set → upgrade → rotate-away choreography.

## Lifecycle Clarifications

- Every system depends on the canonical stub address and the `Pause` target recorded in JSON. `startDeployment` is typically invoked only once—when seeding those anchors and the initial metadata. `Pause` may be replaced (and persisted) without rerunning `startDeployment`; the shared JSON keeps deterministic predictions aligned. All subsequent activity, including incremental feature rollout or emergency response, uses `resumeDeployment` so new layers extend the existing deterministic state instead of recreating it. The same contracts underpin both Foundry and Wake workflows to guarantee environment parity.

## Existing Deployments

- Every persisted deployment JSON must include stub address, owner, system salt string, deployer roster, metadata timestamps, and deterministic proxy records. Resuming a deployment without these fields is unsupported and will revert.
