# CLAUDE.md

## Working mode

Work in small, explicit batches with a checkpoint between each batch. After
completing a batch of changes, stop and report what was done — do not continue
to the next batch without the user confirming. Use the plan file in
`~/.claude/plans/` to track multi-session work; update it after each completed
step and commit the change.
When presenting what was done, also present the next step so I have everything I need
to know what was done and what I'm now saying yes to.


Never end a planning pass with "is the plan good to go?" and then immediately
execute on confirmation. Planning and execution are separate sessions. After
presenting or updating a plan, stop. The user will explicitly say when to start
executing a batch.

## Communication

### Plain language first; slang only after it is defined
Do not use jargon or programmer slang as the primary carrier of meaning in
explanations, reports, or comments. State the point in plain, precise terms first;
after that you may introduce the slang term in brackets — e.g. "an API whose
documented behaviour invites accidental misuse (a 'footgun')" — and reuse the term
freely afterwards, since it is now defined. A reader must never need prior
knowledge of the slang to understand the point. (This is the prose counterpart of
the "no unexplained abbreviations in code" rule below.)

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

### Build shared foundations before the code that depends on them
When a body of work converges many call sites onto a shared abstraction (a common
primitive, library, base, or API), build that abstraction FIRST, then update the
call sites to use it — do not fix the call sites first and retrofit the abstraction
later. Doing the dependents first forces each one through an interim form that was
never the target, then demands a second pass to migrate them onto the abstraction:
double the edits, double the review, and a window where the codebase sits in a shape
no one intended. Building the foundation first also pins down the target API, so each
dependent change is written once, in final form. So when a refactor reveals a missing
shared piece, do not defer it as "architecture for later" and start editing call
sites — stop, build the shared piece, then do the call sites against it.

The architectural fix is worth far more than the convenience of deferring it:
- **Eradicate, don't contain.** The trigger for the change is an observed bad
  practice; the abstraction exists to make the correct thing the path of least
  resistance. Fix the core *and* convert every existing instance to it, and you
  near-eliminate the chance of the bad practice recurring spontaneously elsewhere.
  Paper over the instances and the rotten core remains — it will leak out again.
- **It's now or never.** Deferring the foundational fix dissipates the very
  motivation that surfaced it; "architecture for later" reliably becomes "never",
  leaving you to firefight its absence indefinitely. The moment you notice the
  missing abstraction is the moment to build it.
- **Re-weight the human bias against wide refactors.** Human teams avoid large,
  high-blast-radius changes because manually editing every call site is slow and
  risky — that caution is an artifact of human *speed*, not a law of good
  engineering. You operate orders of magnitude faster and can sweep the entire
  blast radius reliably in a single pass, so the cost calculus that made "patch
  locally" rational for humans does not apply to you. Relearn and rebalance:
  default toward fixing the core and propagating it everywhere, not layering a fix
  on top of a core you know is wrong.

(Complements "Do it right from the start": that rule is about *where* code lives;
this is about the *order* — foundation before dependents.)

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

### Challenge the user's suggestions — don't just comply
Treat the user's proposals as instructions to be *questioned*, not orders to
execute. A suggestion for *how* to do something is an invitation to find the best
way, which may not be the suggested one. Before implementing a proposed approach,
weigh it against the three tests below; if it trips one, say so and put the
alternative on the table *before* writing any code:
- **Reinventing a wheel.** Does it fail to use a tool that already solves this —
  in-house, or an external / off-the-shelf one (even one not yet installed)? Could
  an *existing* tool be extended to cover it rather than a new one created? Prefer
  reusing another tool's *output* over re-deriving what it already computes.
- **Harder to test.** Does it make the result harder to test than a different
  shape would — e.g. fusing steps that could be separated, or forcing elaborate
  fixtures a cleaner design would avoid?
- **Off-standard.** Does it depart from an established industry standard, protocol
  annotation, or idiom for this class of problem when a standard one exists?

Ready agreement is not helpful here: it yields a worse design *and* the wasted
round-trips of discovering that later. A reasoned objection with a concrete
alternative is worth far more than fast compliance — raise it every time one of
the tests fires, even when the suggestion arrived as a direct instruction. Where a
claim about an existing tool's behaviour decides the design, verify it with data
rather than assuming (per the no-"likely" rule below). (Complements "Questions are
not instructions" above and the design-discussion rule under "Other rules".)

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
- **Test interaction with deploy scripts:** unit tests **use** the deploy script abstract contracts (e.g. `HarborYield`, `Swapper`) — by composing them (holding a deploy harness instance) or inheriting them. Throughout this section "inherit" means *use the deploy code*, not specifically Solidity `is`-a. In `setUp()`:
  1. Call `_ensureBaoFactory()` and set the test contract as operator.
  2. Call the deploy script functions in order (e.g. `deployHarborYieldEntry`, then `deployHarborYield`). This exercises the full CREATE3 path.
  3. Override `deploy*Implementation` virtual functions to inject mocks for the contracts THIS chain deploys (e.g. override `deployAutoCompounderImplementation` to return a `MockAutoCompounder_v1`). Dependencies the chain only *references* by predicted address (the shared Swapper, the price oracles) are NOT injected this way — `vm.etch` a mock at their getter address instead (see the mock-mechanism rule below).
  - Tests must **not** manually call `_deployProxyAndRecord`, construct beacons inline with `new`, or reproduce any logic that is already in a `deployABC` function — call the deploy function instead. Direct `new Contract(...)` is only allowed for lightweight test fixtures that never need a predictable address (token mocks, oracle mocks, etc.).
- **A test deploy setup contains only three kinds of code — audit every line against them.** (1) *derive*: **use** the real deploy-script chain (including the upstream repo's — e.g. harbor-yield setups use harbor's `Deploy_*_Minter`, so the Minter/SP/SPM come from `deployForPeg`, not re-implemented). "Use" means compose OR inherit, not Solidity `is`-a specifically: **compose** (hold a deploy harness per stack) when you need independent deploy instances — separate `FactoryDeployer` state per run, e.g. two minter markets on one peg, or keeping harbor and harbor-yield as the separate deploy runs they are in production; **inherit** when one fused instance suffices. Either way the deploy code is reused, never re-implemented. (2) *install mocks at the deploy's own seams*: override `deploy*Implementation` for contracts THIS repo's chain deploys; inline `vm.etch` a mock at the **consumer's getter address** (`_swapperAddress()`, `_wrappedPriceOracleAddress(...)`, `_equivalentOracleAddress(...)`, `_ethPriceOracleAddress(...)`) for a separately-deployed / predicted-address dependency. (3) *call the real deploy functions* (`deployForPeg`, `deployHarborYieldForPeg`, …) + minimal **test-actor glue** (fund the test/owner, grant the test contract roles, `_predictAddress` handles). Anything else is reproduced deploy plumbing and is a defect. **Anti-pattern to catch on sight:** hand-building a `DeploymentTypes.State{…}` and calling `deployX(state)` to place a predicted-address dependency (e.g. the Swapper) — that re-does orchestration the deploy script owns; `vm.etch` the mock at its predicted getter instead (✓ `vm.etch(_swapperAddress(), address(new MockSwapper()).code)` inline in `setUp` vs ✗ `deploySwapper(swapperState)`). When you **write or review** any `*SetUp`/`Deploy*Test` class, read each line that is not a deploy-function call or an override, and confirm it is derive / mock-install / test-actor glue — never a re-implementation of deploy logic.
- **Keep test-composition primitives drivable from an external layer.** A long-term goal is higher-level testing in **Python within the wake environment**; the scenario harnesses / `installContractAt` / compose-blocks should expose clear, minimal *public* entrypoints and not rely on Solidity-inheritance-only assembly, so a future Python/wake layer can compose the same scenarios. Not built now — but let it inform micro-choices (prefer public over internal where a primitive is a composition seam).
- Each UUPS contract composes Initializable + UUPSUpgradeable + ownership mixin directly — don't create "Upgradeable" base contracts that bundle these, as each contract has different init needs (roles, reentrancy, custom state). The "Upgradeable" suffix means something different in OZ (storage-safe proxy variant) and combining meanings causes confusion.
- When adding functions to interfaces in an inheritance hierarchy, avoid creating diamond inheritance. If a function is defined on both an interface and a concrete base, the derived contract must override to resolve the ambiguity. Instead, put the function on only one path — either a new versioned interface (e.g. `IMultipleRewardDistributor_v3`) or directly on the implementation. Prefer eliminating the diamond over resolving it with overrides.
- **Declare errors and events on the interface, not in the contract.** They are part of the contract's ABI surface, so the interface is their single definitional home — shared by the implementation, by any delegatecall/helper libraries that revert or emit them, and by tests. The contract `is` the interface, so it reverts/emits them unqualified (inherited); a library that only imports the interface references them as `IFoo.X` (Solidity ≥0.8.21 allows emitting an event by its qualified `IFoo.Event` name). Referencing an inherited error as `Contract.Error.selector` still resolves, so test assertions keyed on the implementation keep compiling. Don't scatter error/event declarations across the contract and the interface — pick the interface.
- In tests, never create and then remove files or directories — forge runs tests in parallel so you can create a race condition. Write test output to `./results` and leave it there.
- Tests verify *what code is supposed to do*, not merely that lines execute. When asked to improve testing, think: "what is the intended behaviour?" — then construct scenarios that demonstrate the code fulfils that intent. If unsure what a function is supposed to do, ask — the specification is not in the code. Avoid writing tests that only exercise code paths to increase coverage metrics; such tests reinforce any misunderstanding in the implementation and give false confidence. Always add a comment at the top of a test to say what functionality it is testing: keep it concise. Review test quality by behaviour and intent, not by a coverage percentage — high line coverage routinely hides untested behaviour (a loop run with one element, a revert reached for the wrong reason).
- **Coverage data is a check, never the input — do not game it.** When improving a file's tests, do not read the coverage report (or uncovered-lines list) to decide what to write: work from the source and the existing tests, enumerate the code's intended behaviours, and write the tests that are semantically missing. Only after that may coverage be consulted, as an independent check that nothing was overlooked. Writing tests off the uncovered-lines list produces "make line X execute" tests instead of "verify behaviour Y" tests — coverage rises while behaviour stays unverified, which destroys the report's only value: being an ungamed signal of test completeness.
- **Every `expectRevert` asserts a *specific* error, with as many of its parameters as possible.** Never use a bare `vm.expectRevert()` — it matches *any* revert, so the test passes even when the revert comes from an unrelated cause (a setup typo, a different guard). Assert the exact custom error or revert string, and pin the argument values with `abi.encodeWithSelector(Err.selector, expectedArgs…)` whenever they are known and stable. Fall back to selector-only (`vm.expectRevert(Err.selector)`) **only** for the individual arguments that are genuinely runtime-derived and not predictable — assert every argument you can compute or read.
- **Work out the expected error from the code, never from a trace.** Read the function under test, its modifiers, and the libraries/base contracts it inherits to determine which revert it is *written* to throw (e.g. an `onlyOwner`/`onlyRoles` from a Solady-based ownership mixin reverts `Unauthorized()`; Solady ERC20 `_spendAllowance` reverts `InsufficientAllowance()`; an OZ `SafeERC20` call bubbles the inner token revert unchanged), and assert that. Reading the error off a `-vvvv` trace and copying it just enshrines current behaviour — a buggy, wrapped, or coincidental revert would pass by construction. Traces are for debugging, not for choosing the assertion.
- **Exercise every loop at 0, 1, and N (≥ 2) iterations.** A loop tested only against a single-element collection hides both the empty-collection path and multi-element bugs (off-by-one, accumulation/ordering, swap-and-pop, residual carried across iterations). This applies to every iteration over a dynamic collection — arrays, index-mapped registries, reward-token sets, vault lists. One element is not coverage of the loop; build fixtures with 0 and ≥ 2 elements explicitly. If a dependency behaviour is needed to drive a second iteration (e.g. it partially fills so a follow-up pass runs), add that mode to the mock rather than skipping the N case.
- **A mock must match the real dependency's observable behaviour in BOTH directions — never stricter, never more permissive.** Do not add input validation, zero-address / zero-amount guards, allowance checks, or other error-checking to a mock unless the real dependency genuinely has it. Extra strictness in a mock masks a missing check in the code under test: the call reverts *inside the mock*, the test goes green, and the real gap ships. Match the dependency's permissiveness too — e.g. model a Solady-style token's silent transfer-to-zero rather than OpenZeppelin's revert. **The mirror direction is just as dangerous: a mock must not implement functions, selectors, or behaviour the real dependency lacks, and must reproduce the dependency's response to calls it does NOT handle** (a contract with a permissive fallback returns success for unknown selectors; one without reverts). A mock written from the calling code's *assumption* about the dependency's ABI can only ever confirm that assumption — build it from the dependency's *real* ABI, verified against the deployed contract. (Case in point: a Curve crypto pool takes `exchange(uint256,…)` and its Vyper `__default__` silently swallows the `int128` form; a mock that implemented the `int128` form hid a fund-losing mis-encoding that a faithful mock — uint256-only plus a permissive fallback — pins forever.) Do model the real behaviour *modes* the code exercises — a Minter that partially fills up to a fee cap, a vault that accrues yield — so branches and loops stay reachable. The rule is faithful *behaviour*, minimal *validation*, exact *ABI surface*.
- Do not write comments that reference ephemeral or planning artifacts: plan-section identifiers (e.g. `§N`), red/green test-phase labels ("Red:", "Green:"), implementation states ("buggy:", "TODO after X is merged"), or other conditions that become stale once the work is complete. The test comment describes intended behaviour that is always true; anything else belongs in the PR or commit message.
- Before implementing any new contract or significant feature, add a **test plan** to the plan file. List each test by function name, state the single behaviour it verifies, and say whether it is a unit test (mock-based, fast) or a fork test (real mainnet state). The section is not complete until all tests in its plan are written and `forge test --match-path test/TheContract.t.sol` confirms they all pass.
- In tests, prefer `console2.log` over `emit` for debug logging — it shows in `forge test -vvv` output without cluttering the event log. Use the `Fmt` library with `string.concat` for readable formatted messages.
- **One-shot cheatcodes (`vm.prank`, `vm.expectRevert`, `vm.expectEmit`, `vm.expectCall`, `vm.mockCall`-per-call…) bind to the NEXT external call — which is whichever EVM call fires first, not the statement you are looking at.** Argument sub-expressions count: `vm.expectRevert(...); swap(..., _expectedOut(x) + 1)` binds the expectation to the external call *inside `_expectedOut`*, not to `swap`. Helper functions count too: a test helper that performs setup calls (configure a route, set a coin) before the call under test steals the binding. Defend structurally, in this order:
  - **Hoist** every expression that makes an external call into a local *before* the cheatcode, so the guarded statement contains exactly one external call.
  - **Split helpers** into a setup function (called before the cheatcode) and a pure single-call function (the guarded one), and document the single-call contract on the helper.
  - For pranks specifically: never use `vm.prank` — always `vm.startPrank(addr)` / `vm.stopPrank()` pairs, which persist across the whole block so argument evaluation can't steal the prank. Always pair them; never leave a `startPrank` unclosed.

  The failure mode is nasty because it is silent: the stolen binding usually attaches to a view call that succeeds, so an `expectRevert` test fails with a confusing "call did not revert" (or worse, a prank lands on `balanceOf` and the real call runs as the test contract). This class was hit three separate times in one project — via `vm.prank`, via a setup-making helper under `expectRevert`, and via an argument sub-expression under `expectRevert`.
- Unimplemented functions must `revert`, not return a plausible stub value. A function that silently returns 0, false, or an empty array masquerades as implemented and lets tests pass vacuously. Use a descriptive custom error (e.g. `error NotImplemented()`) or a plain `revert("name: not implemented")` so the unimplemented state is immediately visible.
- In tests, prefer exact assertions (`assertEq`) over approximate ones. When the exact value can be computed or read from storage (e.g. a snapshot value read back from the contract), use it directly — never substitute an approximation when the exact value is available. When approximation is genuinely required (e.g. rounding from integer division in an external formula), derive the tolerance analytically — identify the maximum possible error from first principles and use `assertApproxEqAbs` with that specific bound, accompanied by a comment explaining the derivation. Use `BaoTest.assertApprox(actual, expected, absTolerance, relTolerance)` (pytest-style: passes when within either bound) when both an absolute floor and a relative component are independently meaningful — e.g. when the expected value can be zero but a small rounding constant is also possible. Never use a percentage-based tolerance like `0.01e18` as a blanket fallback.
- **Pin a derived tolerance with `assertDiscriminates` when a concrete adjacent wrong value exists.** A tolerance assertion (`assertApprox`/`assertApproxEqAbs`) shows `actual` is close to `expected` but proves nothing about whether the bound is *tight enough to catch a bug* — a later edit can widen it past the very deviation it was sized to exclude and nothing fails. When the tolerance's derivation excludes a specific value a plausible bug would produce — the ceil where the code floors (`expected + 1`), a value just past a conservation dust cliff, an off-by-one-scaled error — lock it in with `BaoTest.assertDiscriminates(actual, expected, tolerance, wrongValue, memo)`: it asserts the band both ADMITS `actual` and REJECTS `wrongValue`, turning a one-off "flip the code, watch it go red" mutation-check into a permanent every-run guard that the bound can't be silently loosened past the bug. **Precondition:** it is only satisfiable — and only meaningful — when the bug's deviation exceeds the legitimate tolerance (`|wrongValue − expected| > tolerance ≥ |actual − expected|`), i.e. the tolerance is the real cliff between correct and that specific wrong. Do NOT force it when the legitimate tolerance dwarfs any adjacent bug (e.g. a large dead-share-dilution bound swamping a sub-wei rounding flip): no single tolerance can both admit the real spread and reject the closer wrong value — get the discrimination from a one-sided invariant instead (a conservation `assertLe(Σparts ≤ whole)` / `assertConserved`, which rejects any over-shoot regardless of the dust bound).
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
  - **A separate deployment the system only references by predicted CREATE3 address** (e.g. price oracles from harbor-price-aggregators, the shared Swapper): mock with **`vm.etch`**, never with the deploy script and never with `vm.mockCall` keyed on a recomputed address. The address getter (`_ethPriceOracleAddress`, `_equivalentOracleAddress`, `_swapperAddress`, `_wrappedPriceOracleAddress`, …) is a **non-overridable pure predicted-address resolver** — used by the `.s.sol` deploy to wire the dep AND by the test to know where to mock, so the two can never desync. In `setUp`, **`vm.etch` the mock inline at that resolved address *after* the deploy chain has run — never before it.** The deploy must reference the dependency by its predicted address while that address is still *codeless* (granting it roles, baking it in as an immutable) — exactly as production does when the dependency is deployed separately — so etching code there before the deploy would mask that path and stop the deploy code from being exercised against a codeless reference. The mock only needs code before the first *call* into it (a mint/read in a test body), which is after the deploy. After etching, set its state with the mock's setters (`etch` copies code, not storage — the mock's constructor / field initializers do NOT apply; for a UUPS mock call its `initialize` afterward). Inline the `vm.etch`+config directly in `setUp` — do **not** wrap it in a **single-use per-setUp** `_installMock*At()` helper (a helper called once per setup reads worse than the visible `vm.etch`, and a `virtual` install hook invites dead overrides). A **genuinely shared** install primitive reused across many setups (e.g. `installContractAt(targetAddress, implementationAddress)`) IS fine — the ban is only on the once-per-setup wrapper; a shared primitive is a foundation, like a shared mock contract. Getting the address from the getter (not a separately-derived key) is what keeps it robust: a key change moves the getter and the install together (a `vm.mockCall` on a separately-derived address silently misses when the key changes, then reverts "call to non-contract"). `vm.etch` also overwrites whatever is present, so it works even if the real contract is already deployed at that address (a deploy-script CREATE3 install would revert on the collision).
  - `vm.mockCall`/`vm.mockCallRevert` remain correct **only** for *behavioural* injection in a single test (force a specific method's return or revert where there is no deployment seam) — never for resolving a dependency's address.
- **Wire dependencies by predicted address, not by a mutable update call.** Don't connect related contracts through a setter that can leave the system half-configured (e.g. `minter.updatePriceOracle`); bake the dependency in as its predicted CREATE3 address (immutable / construction arg) so there is no second source of truth that can drift out of sync.
- **Never copy values — always reference the source.** When a value originates elsewhere (a config function, a protocol constant, an existing variable), call or read that source directly wherever the value is needed. Do not read it once and redeclare it as a new constant, hardcode the literal, or create a duplicate variable of a different name. Copies diverge silently when the original changes and hide the dependency. For example: use `peg.minDeposit()` directly rather than extracting it to a local `uint256 MIN_DEPOSIT = 1e18`.
- **Run project scripts with `yarn`, not the underlying tool directly.** Developers drive this repo through the `yarn` scripts — check `package.json` `scripts` for what's available (e.g. `yarn slither`, `yarn test`, `yarn CI`, `yarn prettier`). These wrappers apply the correct config file, `--filter-paths`, environment, and flags; invoking `forge`/`slither`/etc. directly will miss that setup and can give misleading results. When verifying work or reproducing CI, use the same `yarn` script CI uses.
- **No unexplained abbreviations in code.** Don't use abbreviations in identifiers or comments unless they are widely understood (e.g. `ERC20`, `URL`, `id`, `tx`) or defined once at the point of first use. Do not coin local shorthand. For example, `RPS` in `AutoCompounder_v1.sol` (for reward-per-share) is opaque — and the comments use the same unexplained abbreviation, so there is nothing to decode it against. Prefer the full name (`rewardPerShare`); if a long name genuinely repeats too often to spell out, introduce the abbreviation explicitly in a comment at its first occurrence and use it consistently thereafter.
- **Spell out domain nouns in full — everywhere: contract/library names, function names, variables, and comments.** The short forms we use when *talking* (HY, AC, EQ, SP, SPM, lev, col, wcol/wcoll/wCol) must never appear in code or comments; write the full noun. This is the specific, always-applies case of the abbreviation rule above — these are not "widely understood" outside a live conversation, and a reader six months later has no glossary. The required expansions:
  - `HY` → `HarborYield`
  - `AC` → `AutoCompounder`
  - `EQ` → `equiv`
  - `SP` → `StabilityPool`
  - `SPM` → `StabilityPoolManager`
  - `lev` → `leveraged`
  - `col` → `collateral`
  - `wcol` / `wcoll` / `wCol` / `wColl` → `wrappedCollateral`

  So `acToEquiv`/`_backHarborYieldWithAC`/`wColAmount`/`// unwind the SP position` become `autoCompounderToEquivalent`/`_backHarborYieldWithAutoCompounder`/`wrappedCollateralAmount`/`// unwind the StabilityPool position`. This includes docstrings and inline comments, not just identifiers. (`ERC4626`, `ERC20`, `CR` for collateral ratio where already established, and other genuinely-standard tokens remain fine under the rule above.)
- **Import dependencies normally — don't load them dynamically to work around an environment problem; discuss first.** Import packages at module top with a plain `import`, relying on the controlled, pinned environment (the bin uv env / `bin/.python-version`'s Python 3.13) to provide them. Do not defer an import into a function body, add a `try/except ImportError` fallback, or otherwise load a dependency conditionally so a module can import where the dependency is absent. That masks the real defect — a module running in the wrong / under-provisioned environment — and the correct fix is almost always the *environment* (run the tests in the same bin env they test; pin the interpreter), not the code. For example, `doctor.py` should simply `import tomllib` at the top (the pinned 3.13 has it in the stdlib); a deferred `try tomllib / except toml` fallback only hid that the test runner was using the system Python 3.10 instead of the pinned 3.13. If a lazy or conditional import genuinely seems warranted, stop and discuss it before writing it.
