# Deployment System Design

## Purpose

- Deterministic contract addresses across chains using CREATE3 via the BaoFactory singleton.
- One deploy code path for production scripts and forge tests — context gates select persistence and
  execution behaviour, so tests exercise the same code production runs.
- Owner actions on live (multisig-owned) systems captured as Safe transaction batches.
- Incremental deployments with state preserved as JSON.

## Cross-Chain Determinism

### Why CREATE3 and Nick's Factory?

**CREATE3** provides bytecode-independent deterministic addresses depending only on deployer and salt.
This enables predicting every address before deployment, eliminating order dependencies and enabling
circular references (a contract can bake another's address in as an immutable before that contract exists).

**Nick's Factory** (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) deploys the BaoFactory deterministically
via CREATE2, giving it the same address on every chain. While deployed on 100+ chains, new chains may
require manual deployment — see
[deployment instructions](https://github.com/Arachnid/deterministic-deployment-proxy#usage).

### The BaoFactory Singleton

All CREATE3 deployment goes through one **BaoFactory** proxy at a fixed, predictable address
(deployed via Nick's Factory; see `bao-factory`'s `BaoFactoryDeployment`). It is multisig-owned; the owner
registers **operators** for a limited duration (`setOperator(operator, duration)`), and only a current
operator can deploy through the factory. `predictAddress(saltHash)` gives the CREATE3 address for any salt
without deploying.

**Result**: identical salt + the (identical) factory address ⇒ identical contract addresses on every chain,
and across independent deploy runs on one chain.

## Salt Structure

A full salt string is `<saltPrefix>::<key>`:

- **Salt prefix** — the system-wide namespace (e.g. `harbor_v1`), set exactly once per deploy run by the
  run's entrypoint (`_setSaltPrefix` is write-once; a second set reverts `SaltPrefixAlreadySet`, and
  predicting before any set reverts `SaltPrefixNotSet`). One `FactoryDeployer` instance is one deploy run.
- **Key** — the contract-specific path, built only with `SaltString.key(...)` (e.g.
  `ETH::fxUSD::minter`). Never concatenate salt strings by hand.

Separately-deployed systems (e.g. harbor, harbor-yield, harbor-swap, price aggregators) interconnect by
sharing the salt prefix: each run predicts the others' addresses with `_predictAddress` and can reference
them — even while still codeless — exactly as it references its own not-yet-deployed contracts.

## The Deployer Stack

- **`FactoryDeployer`** — address prediction (`_predictAddress`), proxy deployment + recording
  (`_deployProxyAndRecord`, `_deployProxyViaStubAndRecord`), deployment-state persistence, and end-of-run
  ownership transfer (`_transferAllOwnerships`).
- **`Deployer`** (extends FactoryDeployer) — Safe batch queuing (`queue`/`flush`), local execution of the
  queued transactions (`_executeQueued`), and the `build()`/`run()` template for single-batch scripts.
- **`DeploymentState`** (library) — JSON state files: `load` an existing run's state, `fresh` for a run
  starting from nothing, `save` (atomic write). Paths come from `DEPLOY_STATE_DIR` /
  `DEPLOY_STATE_FILE_READ` / `DEPLOY_STATE_FILE_WRITE`.

## Deploy-Run Lifecycle

The five rules every deploy script follows are stated on `Deployer` itself
(`script/deployment/Deployer.sol`, contract header). In short: direct calls configure only what this run
deployed (temporary ownership); everything on a live system is queued; `_executeQueued()` marks a
synchronization point; batch construction reads only script-time state; each `flush()` is one Safe batch.

The three worked flows:

1. **First deploy of a system** (e.g. harbor's `deployHarborForPeg`, harbor-swap's `Deploy_Swap`): deploy
   contracts, configure them with **direct calls** while the deployer holds temporary ownership, then
   `_transferAllOwnerships()`. Little or nothing is queued.
2. **Deploying against a live system** (e.g. harbor-yield's `deployHarborYieldForPeg`, which grants roles
   on harbor's multisig-owned contracts): configure own contracts directly, **queue** every action on the
   live system, and call `_executeQueued()` at each point where later logic depends on those actions —
   production saves the batches for the multisig to execute in order; tests execute them inline at the same
   points. A later batch may be *constructed* only from state that exists at script time.
3. **Maintenance script on a live system** (e.g. harbor's `UpdateVolatility_*`, `Pause_*`): everything is a
   Safe transaction — override `build()` to queue, and the inherited `run(salt)` saves and (locally)
   executes.

## Context Gates: Production vs Test

The same code runs in both contexts; three gated points differ:

| Gate                       | Script run (forge script)                       | Forge test                          |
| -------------------------- | ----------------------------------------------- | ----------------------------------- |
| `_shouldPersistState()`    | write/read JSON state files                     | in-memory state only                |
| `_shouldWriteBatchFiles()` | write Safe batch JSONs for the multisig         | no files                            |
| `_executeQueued()`         | executes only when `EXECUTE_LOCAL=true` (anvil) | always executes, pranked as owner() |

The first two gates are virtual functions defaulting on the forge execution context, so a test exercising
the persistence or batch-file path itself can force them on (writing under `results/`, where git catches
regressions).

`_executeQueued()` drains what it executes — each queued transaction executes exactly once no matter how
many synchronization points a run has, mirroring the multisig executing each saved batch once. A queued
transaction whose target has no code at execution time reverts (`CallTargetHasNoCode`) rather than letting
the call silently succeed.

## Proxy Deployment and Ownership

- **`_deployProxyAndRecord`** — direct ERC1967 proxy deployment via the factory; for contracts taking an
  explicit deployer/owner in `initialize` (the HarborOwnable pattern).
- **`_deployProxyViaStubAndRecord`** — deploys via `UUPSProxyDeployStub` first, then upgrades with
  initialization. Required by BaoOwnable-style contracts whose `_initializeOwner()` reads `msg.sender`:
  CREATE3 makes `msg.sender = proxy` during direct deployment, so the stub restores the deployer as
  `msg.sender` for initialization.
- The deployer is the temporary owner during the run; `_transferAllOwnerships()` hands every recorded
  proxy to the configured owner (the multisig) at the end.

## Constructor vs Initialize

- **Constructor parameters** (become immutables): for values that don't change independently of code —
  especially addresses of related contracts at predictable CREATE3 addresses. No storage, no setters, less
  bytecode; changing them is a proxy upgrade.
- **Initialize / setter parameters**: for values that genuinely change at runtime. If an update function
  exists for a value, set it via that function rather than duplicating it in `initialize`.

## Testing

- Framework unit tests: `test/deployment/FactoryDeployer.t.sol`, `test/deployment/Deployer.t.sol`,
  `test/deployment/DeploymentState.t.sol` (bao-base), plus the factory's own suite in `bao-factory`.
- Test-side helpers: `test/BaoFactoryTestLib.sol` (`ensureBaoFactory()` — deploys/upgrades the singleton
  factory on a fresh chain or fork and registers the **caller** as operator, so composable deploy
  harnesses self-register).
- Consuming repos compose per-run harness instances (their own `FactoryDeployer` state, prefix set once by
  their deploy) to mirror production's separate deploy runs; see harbor-yield's
  `test/deployment/ComposedScenario.sol`.

## Rejected Alternatives

- **Timeout-based deployer revocation**: fragile deployment-duration assumptions can strand upgrades;
  operators have explicit durations set by the multisig instead.
- **Single-step ERC1967Proxy deployment for BaoOwnable contracts**: CREATE3 makes `msg.sender = proxy`,
  which breaks BaoOwnable's use of `msg.sender` for ownership. The stub adds one step per proxy but keeps
  compatibility; HarborOwnable-style contracts avoid the stub entirely by taking an explicit owner.
- **Safe Singleton Factory**: Nick's Factory exists on more chains.
- **Same-nonce EOA deployment**: a single out-of-order transaction on any chain breaks determinism.
- **Environment auto-detection by chain id**: hidden behaviour; the context gates are explicit functions
  defaulting on the forge execution context, overridable where a test needs the other path.
- **Separate test/production deploy code**: drift between paths is exactly what the context gates exist to
  prevent — tests run the production code with only persistence/execution gated.
