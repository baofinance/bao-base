# CLAUDE.md

## Working mode

Work in small, explicit batches with a checkpoint between each batch. After
completing a batch of changes, stop and report what was done — do not continue
to the next batch without the user confirming. Use the plan file in
`~/.claude/plans/` to track multi-session work; update it after each completed
step and commit the change.

Never end a planning pass with "is the plan good to go?" and then immediately
execute on confirmation. Planning and execution are separate sessions. After
presenting or updating a plan, stop. The user will explicitly say when to start
executing a batch.

## Git

Two repos, opposite rules:

**Project repositories (the code repos) — the user owns all git.** Do not run git
commands that change repository state: no `add`/staging, `commit`, `rm`, `mv`,
`restore`, `checkout`, `reset`, `stash`, `revert`, `branch`, `merge`, `rebase`,
`cherry-pick`, `push`, or `tag`. When a git action is needed (including cleaning up
a file you created by mistake), propose the exact command(s) and let the user run
them. Read-only inspection (`git status`, `git log`, `git diff`, `git show`) is fine.

**Plan repo `~/.claude/plans/` — you own its git, and committing there is required.**
After updating a plan, commit the change yourself (as in Working mode). Do this
without being asked; it is an obligation, not a tolerated exception.

## Design principles

### Fix or remove files that cause errors or warnings
Any file — including legacy config, stale declarations, or superseded build
setup — that causes a compiler error or warning must be fixed or deleted, even
if it is "not the file we're working on". If a file is no longer needed, delete
it; if it needs updating, update it. The codebase should be clean on every build.

### Do it right from the start
Implement code in its intended final location — the right package, file, and
abstraction level — even if it takes longer. Do not put code in a temporary
place intending to move it later: "do it later" defers integration problems
rather than preventing them, and accrues structural debt faster than it is paid
down. If the correct final home isn't clear, stop and resolve that before writing
code.

### One code path for default and non-default cases
Do not write one piece of code to establish a default value and a separate piece
to handle switching to a non-default one. Both should flow through the same path
— a single handler/initialiser that runs for all values including the initial
one. Relatedly, a default value should appear literally once (in the composing
expression), never restated at each early-return branch — duplicated defaults
drift apart silently.

### Catch only the specific error you expect
Only catch the specific, documented condition you expect, and only when there is
a clear reason it is not a defect (e.g. an optional resource that legitimately
may not exist — catch only its "absent" signal). Every other error must propagate
unchanged. Never use a broad catch that swallows unexpected failures; a silent
fallback makes a broken system look like a working one. (Extends the
error-handling rule under "Other rules".)

### Error messages report facts, not assumptions
An error message must state what was observed, not what the writer guesses caused
it. A check knows that a specific thing failed; it does not know whether the cause
is stale state, a hand-edit, a partial write, corruption, or something unforeseen.
Speculating bakes today's best guess into a string that outlives it. Report the
facts (which item, which field, which value) and let cause analysis happen at read
time. (Complements the diagnosis rule under "Other rules": no "likely"/"probably"
without evidence.)

### Stabilise the error path before fixing the cause
When broken code is discovered, fix the error handling first, then the root cause
— as two separate steps. (1) Stabilise: make the failure visible and contained —
surface it, stop retry loops, ensure one failure doesn't cascade. Confirm the
error path works before continuing. (2) Fix the root cause. A system that fails
loudly once is far easier to debug and verify than one that fails silently or
repeatedly.

### Red-green: confirm the test fails before you make it pass
Before implementing any change in behaviour — a bugfix, a new feature, or an
algorithm change — write a test that asserts the intended behaviour and run it
to confirm it *fails* for the right reason first. Then implement the change and
run the test again to confirm it passes. Confirming red first proves the test
actually exercises the change; a test that was green before you touched anything
proves nothing. (The bugfix-specific form of this is under "Other rules".)

### Questions are not instructions
When a message ends with "?", it is a question to answer in the reply — not an
instruction to act on. Answer it before doing anything else, and do not treat it
as a directive to change code or behaviour.

## Other rules
- use forge install/remove for managing submodule dependencies
- Never use bare `"src/..."`, `"script/..."`, or `"test/..."` import paths in any Solidity file — not in contracts, scripts, or tests. Always use the remapped prefix for the repo the file lives in (e.g. `"@harbor/..."`, `"@harbor-script/..."`, `"@harbor-test/..."` for harbor files; `"@bao/..."`, `"@bao-script/..."`, `"@bao-test/..."` for bao-base files). Bare paths create duplicate type identities when files are consumed as a library by another repo, breaking compilation. The only exception is deployed contract source files that cannot be modified.
- In tests and scripts, use interface types (e.g. `IStabilityPool_v3(address)`) not concrete contract types (e.g. `StabilityPool_v3(address)`) when calling functions. This verifies the interface matches the implementation. Concrete types are only for initialisation (constructor, deploy).
  - **Declarations:** use `address`, not typed contract variables. E.g. `address rewardToken = address(new MockERC20(...))`, not `MockERC20 rewardToken = new MockERC20(...)`.
  - **Calls:** cast to the interface at the call site. E.g. `IERC20(rewardToken).balanceOf(user)`.
  - **Setup/mock operations:** casting to concrete types is acceptable for mock-specific functions like `MockERC20(token).mint()`.
- Every branch must have each path on a separate line so coverage tools can distinguish them. Use curly brackets on all if/for/while statements (no single-line bodies). Ternary expressions are fine — formatters already split the branches across lines.
- **Deploy script pattern — three layers per contract:**
  1. `deployABC(state, key, ...config...)` — the **orchestrator**: predicts all addresses from salt keys using `_predictAddress`, calls `deployABCImplementation` with resolved addresses, calls `_deployProxyAndRecord`. Never `virtual`; tests call this directly.
  2. `deployABCImplementation(state, key, ...resolved-addresses...)` — **`virtual`**: receives only fully-resolved addresses (never salt keys or config objects), deploys `new ABC(...)`. Tests override this to inject a mock implementation without touching address-prediction logic.
  3. `deployABCEntryImplementation()` — **`virtual`**: deploys a sub-contract implementation (e.g. an entry impl for a beacon). Tests override this to inject a mock sub-contract implementation.
  - When a contract must bake another contract's address in as an immutable at construction time, split the deploy into a separate `deployABCEntry(state, key)` that deploys the dependency at a predictable CREATE3 address first. The main `deployABC` then predicts that address with `_predictAddress(_key(key, "entrySubkey"))` — no coupling to deployment order.
  - Always build salt strings with `_saltString()` / `_predictAddress()` / `_key()` from FactoryDeployer — never manually concat with `string.concat`. BaoFactory CREATE3 gives deterministic addresses from salts, so contracts can reference each other before deployment.
- **Test interaction with deploy scripts:** unit tests inherit the deploy script abstract contracts (e.g. `HarborYield`, `Swapper`). In `setUp()`:
  1. Call `_ensureBaoFactory()` and set the test contract as operator.
  2. Call the deploy script functions in order (e.g. `deploySwapper`, then `deployHarborYieldEntry`, then `deployHarborYield`). This exercises the full CREATE3 path.
  3. Override `deploy*Implementation` virtual functions to inject mocks for dependencies the test does not exercise (e.g. override `deploySwapperImplementation` to return a `MockSwapper`).
  - Tests must **not** manually call `_deployProxyAndRecord`, construct beacons inline with `new`, or reproduce any logic that is already in a `deployABC` function — call the deploy function instead. Direct `new Contract(...)` is only allowed for lightweight test fixtures that never need a predictable address (token mocks, oracle mocks, etc.).
- **A test deploy setup contains only three kinds of code — audit every line against them.** (1) *derive*: inherit the real deploy-script chain (including the upstream repo's — e.g. harbor-yield setups inherit harbor's `Deploy_*_Minter`, so the Minter/SP/SPM come from `deployForPeg`, not re-implemented). (2) *install mocks at the deploy's own seams*: override `deploy*Implementation` for contracts THIS repo's chain deploys; `vm.etch` a mock at the **consumer's getter address** (`_swapperAddress()`, `_wrappedPriceOracleAddress(...)`, `_equivalentOracleAddress(...)`) for a separately-deployed / predicted-address dependency. (3) *call the real deploy functions* (`deployForPeg`, `deployHarborYieldForPeg`, …) + minimal **test-actor glue** (fund the test/owner, grant the test contract roles, `_predictAddress` handles). Anything else is reproduced deploy plumbing and is a defect. **Anti-pattern to catch on sight:** hand-building a `DeploymentTypes.State{…}` and calling `deployX(state)` to place a predicted-address dependency (e.g. the Swapper) — that re-does orchestration the deploy script owns; `vm.etch` the mock at its predicted getter instead (✓ `DeployETHSetUp._installMockSwapperAt(_swapperAddress())` vs ✗ `deploySwapper(swapperState)` in `DeployACTestSetUp`). When you **write or review** any `*SetUp`/`Deploy*Test` class, read each line that is not a deploy-function call or an override, and confirm it is derive / mock-install / test-actor glue — never a re-implementation of deploy logic.
- Each UUPS contract composes Initializable + UUPSUpgradeable + ownership mixin directly — don't create "Upgradeable" base contracts that bundle these, as each contract has different init needs (roles, reentrancy, custom state). The "Upgradeable" suffix means something different in OZ (storage-safe proxy variant) and combining meanings causes confusion.
- When adding functions to interfaces in an inheritance hierarchy, avoid creating diamond inheritance. If a function is defined on both an interface and a concrete base, the derived contract must override to resolve the ambiguity. Instead, put the function on only one path — either a new versioned interface (e.g. `IMultipleRewardDistributor_v3`) or directly on the implementation. Prefer eliminating the diamond over resolving it with overrides.
- **Declare errors and events on the interface, not in the contract.** They are part of the contract's ABI surface, so the interface is their single definitional home — shared by the implementation, by any delegatecall/helper libraries that revert or emit them, and by tests. The contract `is` the interface, so it reverts/emits them unqualified (inherited); a library that only imports the interface references them as `IFoo.X` (Solidity ≥0.8.21 allows emitting an event by its qualified `IFoo.Event` name). Referencing an inherited error as `Contract.Error.selector` still resolves, so test assertions keyed on the implementation keep compiling. Don't scatter error/event declarations across the contract and the interface — pick the interface.
- In tests, never create and then remove files or directories — forge runs tests in parallel so you can create a race condition. Write test output to `./results` and leave it there.
- Tests verify *what code is supposed to do*, not merely that lines execute. When asked to improve testing, think: "what is the intended behaviour?" — then construct scenarios that demonstrate the code fulfils that intent. If unsure what a function is supposed to do, ask — the specification is not in the code. Avoid writing tests that only exercise code paths to increase coverage metrics; such tests reinforce any misunderstanding in the implementation and give false confidence. Always add a comment at the top of a test to say what functionality it is testing: keep it concise. Review test quality by behaviour and intent, not by a coverage percentage — high line coverage routinely hides untested behaviour (a loop run with one element, a revert reached for the wrong reason).
- **Every `expectRevert` asserts a *specific* error, with as many of its parameters as possible.** Never use a bare `vm.expectRevert()` — it matches *any* revert, so the test passes even when the revert comes from an unrelated cause (a setup typo, a different guard). Assert the exact custom error or revert string, and pin the argument values with `abi.encodeWithSelector(Err.selector, expectedArgs…)` whenever they are known and stable. Fall back to selector-only (`vm.expectRevert(Err.selector)`) **only** for the individual arguments that are genuinely runtime-derived and not predictable — assert every argument you can compute or read.
- **Work out the expected error from the code, never from a trace.** Read the function under test, its modifiers, and the libraries/base contracts it inherits to determine which revert it is *written* to throw (e.g. an `onlyOwner`/`onlyRoles` from a Solady-based ownership mixin reverts `Unauthorized()`; Solady ERC20 `_spendAllowance` reverts `InsufficientAllowance()`; an OZ `SafeERC20` call bubbles the inner token revert unchanged), and assert that. Reading the error off a `-vvvv` trace and copying it just enshrines current behaviour — a buggy, wrapped, or coincidental revert would pass by construction. Traces are for debugging, not for choosing the assertion.
- **Exercise every loop at 0, 1, and N (≥ 2) iterations.** A loop tested only against a single-element collection hides both the empty-collection path and multi-element bugs (off-by-one, accumulation/ordering, swap-and-pop, residual carried across iterations). This applies to every iteration over a dynamic collection — arrays, index-mapped registries, reward-token sets, vault lists. One element is not coverage of the loop; build fixtures with 0 and ≥ 2 elements explicitly. If a dependency behaviour is needed to drive a second iteration (e.g. it partially fills so a follow-up pass runs), add that mode to the mock rather than skipping the N case.
- **A mock must never be *stricter* than the real contract it stands in for.** Do not add input validation, zero-address / zero-amount guards, allowance checks, or other error-checking to a mock unless the real dependency genuinely has it. Extra strictness in a mock masks a missing check in the code under test: the call reverts *inside the mock*, the test goes green, and the real gap ships. Match the dependency's *observable behaviour* including its permissiveness — e.g. model a Solady-style token's silent transfer-to-zero rather than OpenZeppelin's revert. (The flip side: do model the real behaviour *modes* the code exercises — a Minter that partially fills up to a fee cap, a vault that accrues yield — so branches and loops stay reachable. The rule is faithful *behaviour*, minimal *validation*.)
- Do not write comments that reference ephemeral or planning artifacts: plan-section identifiers (e.g. `§N`), red/green test-phase labels ("Red:", "Green:"), implementation states ("buggy:", "TODO after X is merged"), or other conditions that become stale once the work is complete. The test comment describes intended behaviour that is always true; anything else belongs in the PR or commit message.
- Before implementing any new contract or significant feature, add a **test plan** to the plan file. List each test by function name, state the single behaviour it verifies, and say whether it is a unit test (mock-based, fast) or a fork test (real mainnet state). The section is not complete until all tests in its plan are written and `forge test --match-path test/TheContract.t.sol` confirms they all pass.
- In tests, prefer `console2.log` over `emit` for debug logging — it shows in `forge test -vvv` output without cluttering the event log. Use the `Fmt` library with `string.concat` for readable formatted messages.
- In tests, never use `vm.prank` — always use `vm.startPrank(addr)` / `vm.stopPrank()` pairs around the pranked call(s). `vm.prank` only affects the *next* call, and the "next call" is whichever EVM call fires first — which includes argument sub-expressions. Writing `vm.prank(alice); foo(token.balanceOf(alice))` silently applies the prank to `balanceOf`, not `foo`, so `foo` runs as the test contract and fails confusingly (e.g. an unexpected allowance/permission revert). `startPrank`/`stopPrank` persist across the whole block, so argument evaluation can't steal the prank. Always pair them; never leave a `startPrank` unclosed.
- Unimplemented functions must `revert`, not return a plausible stub value. A function that silently returns 0, false, or an empty array masquerades as implemented and lets tests pass vacuously. Use a descriptive custom error (e.g. `error NotImplemented()`) or a plain `revert("name: not implemented")` so the unimplemented state is immediately visible.
- In tests, prefer exact assertions (`assertEq`) over approximate ones. When the exact value can be computed or read from storage (e.g. a snapshot value read back from the contract), use it directly — never substitute an approximation when the exact value is available. When approximation is genuinely required (e.g. rounding from integer division in an external formula), derive the tolerance analytically — identify the maximum possible error from first principles and use `assertApproxEqAbs` with that specific bound, accompanied by a comment explaining the derivation. Use `BaoTest.assertApprox(actual, expected, absTolerance, relTolerance)` (pytest-style: passes when within either bound) when both an absolute floor and a relative component are independently meaningful — e.g. when the expected value can be zero but a small rounding constant is also possible. Never use a percentage-based tolerance like `0.01e18` as a blanket fallback.
- Prefer immutable constructor arguments over configurable storage for addresses of related contracts deployed at predictable proxy addresses. The related contract can be upgraded via its own proxy without the consuming contract needing a setter. This saves bytecode (no setter function, no zero-address checks, no storage reads) and gas. Only use storage for addresses that genuinely need to change independently of contract upgrades.
  - **Exception — beacon proxies:** immutables are stored in the *implementation* bytecode and are therefore shared across all proxies that point to the same beacon. Per-proxy state (e.g. the `vault` address that differs for each `HarborYieldEntry_v1` instance) must live in per-proxy storage (ERC-7201 slot or plain storage). Use immutables only for values that are genuinely the same for every proxy instance (e.g. the beacon address itself, baked into the factory).
- Never modify a deployed contract's source file. Check `deployments/*.state.json` for deployed contracts. To add functionality: inherit from the deployed version (e.g. `Minter_v3 is Minter_v2`) if the changes are additive, or clone and modify if the inheritance chain doesn't work. The proxy upgrade mechanism allows swapping implementations, but the old source must remain unchanged for audit traceability.
- Never read files that are likely to contain secrets — `.env`, `.env.*`, `*.pem`, `*.key`, `credentials*`, `*.secret`, `id_rsa*`, etc. — unless the user explicitly asks for it. This applies even when investigating something unrelated (e.g. resolving a symlink, looking for shell hooks): skip the file. Once a secret is read by a tool call, the contents are in the conversation transcript and must be treated as compromised. If you need information *about* such a file (existence, size, ownership), use `ls -la`, not `cat`. Match the scope of investigation to the actual question being asked.
- When discussing design decisions, do not present disconnected multiple-choice questions. Instead, write out the full picture first — user flows, accounting, consequences — so the decision context is clear. Present a recommendation with reasoning, not a menu of options without enough background. Use the plan document or design docs for detailed analysis, not the question dialog.
- Do not create functions that are only called once. Inline the logic instead.
- When diagnosing an issue, do not use words like "likely", "probably", or "may" to describe a root cause. Either verify the hypothesis with data (dry run, log, trace) or state explicitly that it is unverified. Never proceed with a fix based on an unverified hypothesis.
- When the user reports a problem, fix it — do not unilaterally decide the problem is out of scope, pre-existing, already resolved by another fix, or someone else's concern. If you believe any of those things, say so and ask whether the user still wants it addressed. Never declare a judgement like "this is pre-existing" or "the root cause is X" and then act on it without confirmation. Present your reasoning, then ask.
- When fixing bugs, follow this process: (1) write a test that fails because of the bug, (2) write the fix, (3) run the test again to confirm it passes. This applies to both Solidity and script/tooling bugs.
- Plan files are under git at `~/.claude/plans/`. After modifying a plan file, commit it with a short message describing the change (e.g. `git -C ~/.claude/plans commit -am "added D.1 versioned directories"`). This allows reverting mistakes.
- When fixing error handling, do not silently skip or suppress errors. If something fails, the failure should be visible and the process should fail clearly. Do not work around errors by hiding them unless explicitly asked to.
- In bash, `set -e` does NOT catch failures in `[[ ]]` conditionals, variable assignments (e.g. `x=$(failing_cmd)`), commands in pipelines (use `set -o pipefail` AND check `${PIPESTATUS[@]}`), or sourced scripts. Always check exit status explicitly with `${PIPESTATUS[0]}` or `$?` after critical commands rather than relying on `set -e` alone.
- Three ownership patterns for UUPS contracts:
  - **BaoOwnable** (legacy): `_initializeOwner(finalOwner)` uses `msg.sender` as temp owner. Deploy via `_deployProxyViaStubAndRecord` (needs UUPSProxyDeployStub so msg.sender = FactoryDeployer, not BaoFactory). Used by: Minter_v2, StabilityPool_v3, SPM, Genesis, LeveragedToken, PeggedToken.
  - **HarborOwnable** (modern): `_initializeOwner(deployerOwner, pendingOwner)` takes explicit deployer. Deploy via `_deployProxyAndRecord` (direct, no stub). Used by: RewardAlias, all new contracts.
  - **HarborFixedOwnable** (hardcoded): Owner is immutable constructor param (Harbor multisig). Deploy via `_deployProxyAndRecord` with empty initData. Used by: HarborPauser_v1.
- Always use HarborOwnable/HarborOwnableRoles over BaoOwnable/BaoOwnableRoles. They are near-drop-in replacements that take explicit `(deployerOwner, pendingOwner)` instead of relying on `msg.sender`. They don't need the UUPSProxyDeployStub — deploy via `_deployProxyAndRecord` (direct), not `_deployProxyViaStubAndRecord`. When upgrading a contract from BaoOwnable to a new version, switch to HarborOwnable.
- Never use module-level or contract-level flags/booleans to communicate state between functions within a single call. If a function needs to behave differently based on context, pass the context explicitly via parameters or use separate functions. Hidden state makes code harder to reason about and introduces coupling that isn't visible in function signatures. Use explicit parameters or dedicated function variants instead.
- **Deployment config mixins**: each deployment config dimension is a standalone mixin contract with `virtual` functions providing useful defaults (e.g. `ConfigPriceVolatility_130_stable`, `ConfigStabilityPool`, `ConfigCollateral_fxUSD_mainnet`). The top-level market config (e.g. `ConfigMarket_ETH_fxUSD_mainnet`) inherits from all relevant mixins and overrides only what differs. Config values belong in the mixin that owns their domain: fee ratios go in the volatility config (same contract as `minterConfig()`), oracle addresses go in the collateral config (same contract as `wrappedCollateralToken()`). Do not create a separate mixin for a config value that naturally belongs to an existing one — that fragments the config and requires unnecessary overrides in every market.
- **Test deploy overrides for fork-test setup classes**: deployment test setup classes (e.g. `DeployEURSetUp`) inherit the real deploy script chain (`Deploy_EUR_Minter → DeployMintersShared → AutoCompounder`). When a deploy function needs a contract address that doesn't exist yet in production (e.g. an oracle not yet deployed), override the relevant `deploy*Implementation` virtual function in the test setup class to substitute a mock. The override calls `super` so the rest of the deploy logic is unchanged. Never add test-only fallback logic to production deploy scripts.
- **Mock contracts must be UUPS proxy-compatible**: mock contracts that stand in for production UUPS-upgradeable contracts must be deployable as proxy implementations. Add `Initializable`, call `_disableInitializers()` in the `constructor()`, and expose an `initialize(...)` function with the **same signature as the production contract's `initialize`** instead of using constructor arguments for state. When tests need the mock at a specific address (e.g. a CREATE3-predicted address), the deploy script will call `_deployProxyAndRecord` with the mock as implementation — no `ERC1967Proxy` is needed in the test itself. The matching signature means the same `abi.encodeCall(ProductionContract.initialize, ...)` used in the deploy script works unchanged with the mock.
- **Choose the mock mechanism by how the contract is reached — override for repo-deployed, `vm.etch` for predicted-address.**
  - **Deployed by this repo's deploy chain** (part of the system under test: the vault, its entries, AutoCompounders, an ERC-4626 adapter): mock via the `deploy*Implementation` virtual override (above). The deploy script installs the mock at the predicted address as part of the normal flow — tests do not place it themselves.
  - **A separate deployment the system only references by predicted CREATE3 address** (e.g. price oracles from harbor-price-aggregators, the shared Swapper): mock with **`vm.etch`**, never with the deploy script and never with `vm.mockCall` keyed on a recomputed address. Get the address from the **same getter the consumer uses** (`predictEthPriceOracleAddress`, `_resolveEquivalentOracle`, `_swapperAddress`, `_resolveWrappedPriceOracle`, …) — never recompute it from a separate key/salt expression in the test — then `vm.etch` the mock's runtime code at that address and set its state with the mock's setters (`etch` copies code, not storage; for a UUPS mock call its `initialize` afterward). Getting the address from the getter is what keeps it robust: a key change moves the getter and the install together so they cannot desync (a `vm.mockCall` on a separately-derived address silently misses when the key changes, then reverts "call to non-contract"). `vm.etch` also overwrites whatever is present, so it works even if the real contract is already deployed at that address (a deploy-script CREATE3 install would revert on the collision).
  - `vm.mockCall`/`vm.mockCallRevert` remain correct **only** for *behavioural* injection in a single test (force a specific method's return or revert where there is no deployment seam) — never for resolving a dependency's address.
- **Wire dependencies by predicted address, not by a mutable update call.** Don't connect related contracts through a setter that can leave the system half-configured (e.g. `minter.updatePriceOracle`); bake the dependency in as its predicted CREATE3 address (immutable / construction arg) so there is no second source of truth that can drift out of sync.
- **Never copy values — always reference the source.** When a value originates elsewhere (a config function, a protocol constant, an existing variable), call or read that source directly wherever the value is needed. Do not read it once and redeclare it as a new constant, hardcode the literal, or create a duplicate variable of a different name. Copies diverge silently when the original changes and hide the dependency. For example: use `peg.minDeposit()` directly rather than extracting it to a local `uint256 MIN_DEPOSIT = 1e18`.
- **Run project scripts with `yarn`, not the underlying tool directly.** Developers drive this repo through the `yarn` scripts — check `package.json` `scripts` for what's available (e.g. `yarn slither`, `yarn test`, `yarn CI`, `yarn prettier`). These wrappers apply the correct config file, `--filter-paths`, environment, and flags; invoking `forge`/`slither`/etc. directly will miss that setup and can give misleading results. When verifying work or reproducing CI, use the same `yarn` script CI uses.
- **No unexplained abbreviations in code.** Don't use abbreviations in identifiers or comments unless they are widely understood (e.g. `ERC20`, `URL`, `id`, `tx`) or defined once at the point of first use. Do not coin local shorthand. For example, `RPS` in `AutoCompounder_v1.sol` (for reward-per-share) is opaque — and the comments use the same unexplained abbreviation, so there is nothing to decode it against. Prefer the full name (`rewardPerShare`); if a long name genuinely repeats too often to spell out, introduce the abbreviation explicitly in a comment at its first occurrence and use it consistently thereafter.
