# Deployment System Design

## Purpose

- Provide a defense-in-depth bootstrap ("stem") that keeps UUPS proxies inert until an approved implementation is installed.
- Guarantee deterministic proxy addresses across chains and incremental phases.
- Enable controlled deployer rotation without forfeiting upgrade authority or compromising proxy determinism.

## Core Components

- **UUPSProxyDeployStub**
  - Single instance per chain; address is part of the CREATE3 deterministic input.
  - Stateless bootstrap with a minimal storage layout reserved for role management.
  - Records the controlling multisig ("owner") and maintains a revocable set of authorized deployers.
  - Exposes `grantDeployer` / `revokeDeployer` entry points gated by the owner; deployers call `upgradeTo` / `upgradeToAndCall` while authorized.
  - Supports two-step ownership transfer so the multisig can change without redeploying the stub.
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
  - Holds exclusive rights to grant or revoke deployers and to transfer ownership via a two-stage handover.
  - Retains emergency power to revoke all deployers before calling `upgradeTo`.
- **Deployers**
  - Granted per session; authorization is stored on the stub so it survives across deployment harnesses or upgrades.
  - Revocation happens explicitly (`revokeDeployer`) to avoid implicit assumptions about timeout windows.
  - Multiple concurrent deployers are possible but discouraged; JSON serialization records the active list for auditability.

## Deployment Workflow

- **Fresh Deployment (`startDeployment`)**
  1. Require lifecycle state `Uninitialized`.
  2. Accept explicit inputs: stub address, system salt string, owner address, optional initial deployer list.
  3. Verify stub ownership and grant deployer access on-chain.
  4. Persist metadata and mark lifecycle `Active`.
- **Resumed Deployment (`resumeDeployment`)**
  1. Require lifecycle state `Uninitialized`.
  2. Load JSON, restore metadata (stub, salt, owner, prior deployments, predicted addresses).
  3. Optionally grant new deployers via the stub before any further proxy deployments; this unlocks layered upgrades where new modules or implementations are added in subsequent phases.
  4. Mark lifecycle `Active`.
- **Incremental Phases**
  - Each phase loads JSON, grants the current deployer, performs deployments, saves JSON.
  - Phases do not depend on previous deployer keys; address determinism flows from stub + salt.
- **Finish (`finishDeployment`)**
  - Calls `finalizeOwnership` internally before marking lifecycle `Finished`.
  - Revokes any outstanding deployer authorizations and updates metadata timestamps.

## Deterministic Proxy Guarantees

- Predictive checks run before and after each CREATE3 deployment to ensure the stored prediction matches the actual address.
- Stub address and system salt string are immutable inputs to address derivation and must be provided (or restored) before any proxy deployment.
- JSON persistence records both predicted and realized proxy addresses to detect drift when resuming.

## Testing Coverage

- **Unit Tests**
  - Stub role management: grant, revoke, owner transfer, unauthorized upgrades revert.
  - Lifecycle enforcement: `startDeployment` and `resumeDeployment` exclusivity, `finishDeployment` idempotency.
  - Prediction accuracy: `predictProxyAddress` equals actual deployment address.
- **Integration Tests**
  - Incremental deployment phases with different deployers; verifies deterministic addresses and successful upgrades.
  - Cross-chain equivalence simulated via repeated runs with distinct deployer accounts but fixed stub + salt.
  - Finish flow ensures ownership transfers before metadata finalization.
  - Layered resumptions that attach additional contracts or upgrade implementations after loading from JSON.
  - Pause / resume lifecycle that upgrades proxies to the pause stem and back, confirming authorization and determinism remain intact.

## Rejected Alternatives

- **Timeout-Based Deployer Revocation**: Rejected in favor of explicit `revokeDeployer` because timeouts introduce fragile assumptions about deployment duration and can strand upgrades mid-phase.
- **Per-Proxy Stub Deployments**: Rejected because each stub address alters CREATE3 outcomes; a single shared stub per chain is mandatory.
- **Proxy-Level Access Controls**: Rejected to avoid storage collisions with production implementations; all deployer management remains in the stub.

## Usage Guide

- **Initial Set-Up**

1.  Deploy the single-chain `UUPSProxyDeployStub` and initialize it with the multisig owner. Deploy the dedicated pause stem (a `Stem_v1` instance locked to a Pause multisig) so it is available for emergency upgrades.
2.  Call `startDeployment` with stub address, owner, system salt string, and initial deployer(s).
3.  Execute proxy deployments; each call checks deterministic predictions automatically. To pause a contract, authorize a deployer and upgrade the proxy to the pause stem; resume by upgrading back to the prior implementation when safe.
4.  Invoke `finishDeployment` (which finalizes proxy ownership) and save JSON.

- **Incremental / Resumed Deployment**
  1. Call `resumeDeployment` with the saved JSON and the new deployer identity.
  2. The harness restores registry state, grants the deployer on-chain via the stub, and resumes deployments.
  3. After completing the phase, call `finishDeployment` (or re-save JSON if continuing later).
- **Governance Changes**
  - The multisig owner can run the two-step transfer on the stub to migrate governance.
  - Deployers revoke themselves by calling `revokeDeployer` (owner can enforce revocation if needed).
  - Upgrades follow a consistent flow: owner grants a deployer, the deployer performs `upgradeTo` / `upgradeToAndCall` via the stub-governed proxy, and the grant is revoked immediately afterward.

## Pausing Model

- A dedicated pause stem (based on `Stem_v1`) is deployed once and owned permanently by the Pause multisig.
- Pausing a proxy is achieved by authorizing a deployer who upgrades the proxy to delegate to the pause stem; the stem’s fallback reverts all calls, halting contract behavior.
- Resuming service upgrades the proxy back to the previous (or patched) implementation using the same grant → upgrade → revoke choreography.

## Lifecycle Clarifications

- Every system depends on the canonical stub and pause stem addresses. `startDeployment` is typically invoked only once—when seeding those anchors and the initial metadata. All subsequent activity, including incremental feature rollout or emergency response, uses `resumeDeployment` so new layers extend the existing deterministic state instead of recreating it.

## Existing Deployments

- Every persisted deployment JSON must include stub address, owner, system salt string, deployer roster, metadata timestamps, and deterministic proxy records. Resuming a deployment without these fields is unsupported and will revert.
