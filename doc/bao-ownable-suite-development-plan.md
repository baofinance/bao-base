# BaoOwnable Suite Development Plan

## Goal

Deliver the ownable suite changes with a clean separation between ownership backends and roles, plus matching tests:

- Upgrade `BaoOwnable` to support an additional initializer that does not use `msg.sender`.
- Add `BaoFixedOwnable` (immutable/bytecode-backed ownership; one implementation per instance).
- Add `BaoFixedOwnableRoles`.
- Refactor existing roles / ownable layering so roles logic is backend-agnostic and re-used across slot-backed and immutable-backed owners.

This plan is written to be tracked using markdown checkboxes.

## Agreements

- The new `BaoOwnable` initializer will use the parameter name `pendingOwner` (not `finalOwner`).
- `BaoFixedOwnable` assumes **one implementation per instance** (i.e., do not point multiple unrelated proxies at the same implementation when ownership is immutable/bytecode-backed).
- We will do the full refactor that separates roles from ownership because:
  - it keeps the codebase clean, avoiding downstream confusion,
  - it forces existing test layers to execute against the refactored code (higher confidence),
  - it makes it easier to add future owner backends without copying role logic.
- Deliverables include the above plus the necessary refactors to existing `BaoRoles` / `BaoRoles_v2` and roles-enabled ownables.
- For every new ownable type introduced (e.g. `BaoFixedOwnable`, `BaoFixedOwnableRoles`), we will add a minimal `Derived*` contract in the corresponding `test/_sizes/*.t.sol` file so it appears in the size report.

## Naming / Semantics

### `BaoOwnable`

Storage-backed (ERC-7201 slot) owner with a one-shot, time-bounded transfer.

### `BaoFixedOwnable`

Bytecode-backed (immutables) ownership with no storage writes for ownership state.
Ownership semantics mirror `BaoOwnable_v2` behavior (time-based owner resolution with a scheduled switch).

### `BaoFixedOwnableRoles`

Roles-enabled version of `BaoFixedOwnable`.

## Rationale (short)

- Adding an explicit `(deployerOwner, pendingOwner)` initializer to `BaoOwnable` enables deployments where the deployer/harness is not `msg.sender` from the implementation’s point of view (factories, meta-deployers, scripted harnesses), while keeping existing callers unchanged.
- Using immutables in `BaoFixedOwnable` is only safe under the “one implementation per instance” deployment model; this is explicitly assumed here.

## Phase 0 — Baseline & Constraints

- [ ] Confirm baseline tests pass before changes (`forge test`).
- [ ] Confirm no new contracts beyond the agreed three.
- [ ] Confirm `BaoFixedOwnable` is deployed one-implementation-per-instance in the intended workflows.

## Phase 1 — Refactor Roles/Owner Separation (Core Change)

### 1.1 Preserve semantics (explicit)

- [ ] Enumerate the semantic behavior of existing roles contracts (`BaoRoles`, `BaoRoles_v2`) that must remain unchanged:
  - [ ] roles storage layout (role slot seed and slot derivation)
  - [ ] authorization rules for grant/revoke
  - [ ] revert behavior and error selectors
  - [ ] event emission (`RolesUpdated`)
  - [ ] ERC165 interface support
- [ ] Enumerate the semantic behavior of owner-or-roles / roles-or-owner gating that must remain unchanged.

### 1.2 Introduce a backend-agnostic roles core

- [x] Add a new internal roles base (name TBD but intention-revealing) that implements all role logic without assuming how ownership is stored.
- [ ] The roles core must require a single ownership hook supplied by the inheriting ownable backend:
  - [x] preferred hook: `_isOwner(address user) internal view returns (bool)`
  - [x] roles core derives `_checkOwner()` behavior from `_isOwner(msg.sender)` (or equivalent)
- [x] Ensure the roles core does not hard-inherit any owner implementation.

### 1.3 Rebuild existing roles variants as thin wrappers

- [x] Update the slot-backed roles contract (`BaoRoles`) to become a thin wrapper over the roles core:
  - [x] implements `_isOwner(user)` using the slot-backed owner mechanism
  - [x] preserves all public/external behavior and interface support
- [x] Update the immutable/time-based roles contract (`BaoRoles_v2`) to become a thin wrapper over the roles core:
  - [x] implements `_isOwner(user)` using the time-based `_owner()` mechanism
  - [x] preserves all public/external behavior and interface support

### 1.4 Verify roles tests against refactor

- [x] Run the existing roles-focused test suites (and any inheritors) to validate no semantic regression.

### 1.5 Wire-up roles-enabled ownables

- [x] Confirm `BaoOwnableRoles` and `BaoOwnableRoles_v2` continue to work without logic duplication:
  - [x] confirm linearization / overrides compile cleanly
  - [x] confirm `supportsInterface` behavior is preserved

## Phase 2 — Upgrade `BaoOwnable` (API + docs)

### 1.1 Add explicit initializer

- [ ] Add a new internal initializer on `BaoOwnable`:
  - [ ] Signature includes both `deployerOwner` and `pendingOwner`.
  - [ ] Sets current owner to `deployerOwner` (never uses `msg.sender`).
  - [ ] Sets pending owner to `pendingOwner`.
  - [ ] Preserves the existing `+3600` expiry behavior.
  - [ ] Preserves all revert behavior (already-initialized, cannot-complete-transfer).
  - [ ] Emits the same `OwnershipTransferred` events as the existing path.

### 1.2 Deprecate the legacy initializer

- [ ] Mark the existing `_initializeOwner(address pendingOwner)` NatSpec as `@deprecated`.
- [ ] Add a brief rationale: callers should prefer the explicit initializer where possible.
- [ ] Do not change legacy semantics.

## Phase 3 — Implement `BaoFixedOwnable`

### 2.1 Contract behavior

- [ ] Implement `BaoFixedOwnable` with immutable ownership parameters.
- [ ] Provide an `owner()` view that returns the correct owner before/after the scheduled transfer time.
- [ ] Provide `onlyOwner` gating consistent with the time-based owner.
- [ ] Emit the two `OwnershipTransferred` events (matching the existing `BaoOwnable_v2` expectation):
  - [ ] `address(0) -> beforeOwner`
  - [ ] `beforeOwner -> ownerAt`

### 2.2 Interface support

- [ ] `supportsInterface` matches the chosen interface target (expected: `IBaoOwnable_v2`-style).

## Phase 4 — Implement `BaoFixedOwnableRoles`

### 3.1 Roles behavior

- [ ] Implement roles operations (grant/revoke/renounce) and role checks.
- [ ] Ensure all role mutations are owner-gated.
- [ ] Ensure role checks are compatible with existing `BaoRoles(_v2)` expectations.

### 3.2 Interface support

- [ ] `supportsInterface` includes both ownable and roles interface IDs.

## Phase 5 — Tests (unit)

### 4.1 Extend `BaoOwnable` tests for the new initializer

In the existing `BaoOwnable` tests:

- [ ] Add a derived test contract entrypoint that calls the new initializer.
- [ ] Add tests proving:
  - [ ] Owner becomes `deployerOwner` even when caller is different.
  - [ ] Pending owner and expiry are correct.
  - [ ] Transfer completion rules are unchanged.
  - [ ] Re-init protection is unchanged.
  - [ ] Legacy initializer still behaves exactly the same.

### 4.2 Add `BaoFixedOwnable` tests (mirror v2)

- [ ] Create a `BaoFixedOwnable` test suite mirroring `BaoOwnable_v2`:
  - [ ] event expectations
  - [ ] time-based ownership transition
  - [ ] onlyOwner gating pre/post transition
  - [ ] `supportsInterface`

### 4.3 Add `BaoFixedOwnableRoles` tests (mirror v2 roles)

- [ ] Create a `BaoFixedOwnableRoles` test suite mirroring `BaoOwnableRoles_v2`:
  - [ ] role grant/revoke behaviors
  - [ ] onlyOwner/onlyRoles/onlyOwnerOrRoles gating
  - [ ] `supportsInterface`

## Phase 6 — Tests (upgrade paths)

### 5.1 BaoOwnable initializer upgrade coverage

- [ ] Add upgrade tests proving that upgrading between implementations preserves state/behavior.
- [ ] Add explicit coverage for the new BaoOwnable initializer path.

### 5.2 BaoOwnable ↔ BaoFixedOwnable upgrade coverage (documented assumption)

Because `BaoFixedOwnable` ownership is immutable/bytecode-backed:

- [ ] Only add “upgrade between the two” tests if the upgrade path is part of intended production usage.
- [ ] If included, tests must explicitly document that the target implementation is one-per-instance.

## Phase 7 — Regression & Review

- [ ] Run the focused test set for ownables and deployment upgrade tests.
- [ ] Run full `forge test`.
- [ ] Ensure no unrelated files were reformatted.
