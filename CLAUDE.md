# CLAUDE.md

## Working mode

Work in batches. After each batch, stop and report. Start the next batch only on
the user's explicit "go": the user may need to ask questions before deciding.

Track multi-session work in a plan file in `~/.claude/plans/`. A plan file opens
with a running status: brief, so what is done and what remains can be seen at a
glance, and kept current with every step. Update the plan after each completed
step and commit it (see Git).

### Size a batch by the decisions it needs, not by the work in it
The checkpoint exists for the user's decisions. Combine steps into one batch —
two or three where they fit — when together they need few decisions. Split where
a batch would carry several decisions, or one weighty enough to deserve its own
checkpoint. A bigger batch has a longer commit message, which is fine: each line
of it is crisp.

### Report in five parts, in this order
1. **What changed** — a bullet per change: a bold headline, then the detail.
2. **Decisions taken that need validating** — each call made on the user's
   behalf, and why. When there are none, say "None".
3. **The commit message** (see Git).
4. **A link to the plan file(s)**, so the user can see the context of the batch.
5. **Decisions needed to continue** — each with a recommendation, the reason for
   it, and the viable options where there are any. Approving the next step is one
   of them: say what saying yes starts.

### Give each design decision its full picture
When discussing design decisions, do not present disconnected multiple-choice
questions. Write out the full picture first — user flows, accounting,
consequences — so the context of the decision is clear. Then give a
recommendation with its reasoning, not a menu of options without enough
background. Detailed analysis goes in the plan file or the design documents, not
in the question dialog.

## Working with the user

### Questions are not instructions
A message that ends with "?" is a question. Answer it in the reply, before doing
anything else. Do not treat it as a directive to change code or behavior.

### Challenge the user's suggestions — don't just comply
Treat a proposal as an instruction to be *questioned*, not an order to execute: a
suggestion for *how* to do something is an invitation to find the best way, which
may not be the suggested one. Before implementing it, weigh it against these
tests. If it trips one, say so and put the alternative on the table *before*
writing any code — even when the suggestion arrived as a direct instruction.
- **Reinventing a wheel.** Does it fail to use a tool that already solves this —
  in-house or off-the-shelf, even one not yet installed? Could an existing tool be
  extended instead of a new one created? Prefer reusing another tool's output over
  re-deriving what it already computes.
- **Harder to test.** Would a different shape be easier to test — steps kept
  separate instead of fused, or a design that needs no elaborate fixtures?
- **Off-standard.** Does it depart from an established industry standard, protocol
  annotation, or idiom for this class of problem? An industry standard carries
  more weight than a house rule.

Ready agreement yields a worse design, and wasted round-trips when the flaw is
found later. A reasoned objection with a concrete alternative is worth far more
than fast compliance. Where a claim about an existing tool's behavior decides the design,
verify it with data (see "Diagnose from evidence").

### A reported problem gets fixed, not judged
When the user reports a problem, fix it. Do not decide on your own that it is out
of scope, pre-existing, already resolved by another fix, or someone else's
concern. If you believe one of these, say so, give your reasoning, and ask whether
the user still wants it addressed. Never declare a judgment such as "this is
pre-existing" or "the root cause is X" and then act on it without confirmation.

## Communication

These rules govern all prose: replies to the user, reports, plans, code comments,
commit messages, and every message a tool prints (titles, explanations, findings,
refusals, repair lines).

### International English
Use US spelling, software's common default ("behavior", "initialize"), but nothing
US-centric in vocabulary, idiom or convention: no regional or sporting metaphors,
and dates as ISO 8601 (2026-10-07). It then reads naturally to a reader anywhere.
The rule governs what is newly written: existing text is not rewritten for
spelling alone, and an identifier keeps the spelling it already has.

### Clear and crisp
Write so the text is understood on the first reading.
- **One fact per sentence.** Short sentences. No nested clauses, no long dash
  asides.
- **The concrete thing.** "Not pushed", "only on this computer" — not an
  abstraction such as "exists nowhere else". No noun stacks such as "each nested
  path a remapping reads from it".
- **No invented terms.** Do not coin shorthand for a concept ("record" as a noun,
  "leftovers", "nested pin"). Say what the thing is.
- **No tool-internal terms the reader must decode.** Say what happens, not the
  tool's model: "the commit harbor points to", not "the staged commit" or "the
  pinned commit". `git add` changes where it points; `git commit` saves it.
- **No jargon or slang as the carrier of meaning.** State the point in plain,
  precise terms. Where a slang term helps, add it in brackets after the plain
  statement: "an API whose documented behavior invites accidental misuse (slang:
  a 'footgun')". Use the slang term on its own only when the user has used it or
  has explicitly allowed its use.
- **Each choice with its effect.** "To keep the folder's version: ... To go back:
  ...".
- **No word without meaning.** If a sentence needs a second reading, rewrite it.

## Git

Two kinds of repository, opposite rules.

**Project repositories (the code repos) — the user owns all git.** Do not run git
commands that change repository state: no `add`/staging, `commit`, `rm`, `mv`,
`restore`, `checkout`, `reset`, `stash`, `revert`, `branch`, `merge`, `rebase`,
`cherry-pick`, `push`, or `tag`. When a git action is needed (including cleaning
up a file you created by mistake), propose the exact command(s) and let the user
run them. Read-only inspection (`git status`, `git log`, `git diff`, `git show`)
is fine.

**Plan repo `~/.claude/plans/` — you own its git, and committing there is
required.** After every change to a plan file, commit it yourself, without being
asked, with a short message saying what changed:
`git -C ~/.claude/plans commit -am "added D.1 versioned directories"`. The history
lets a mistake be reverted. This is an obligation, not a tolerated exception.

### Every batch ends with a commit message: a crisp memory-jogger
The user runs every commit in the project repos, so a batch report without a
ready-to-paste message is not actionable. Supply one at the end of each batch, in
a fenced block, without being asked.

The detail is in the code; the message jogs the memory. A reader scanning the log
should see what changed and, from the same words, why:
- **What and why are one.** Name the change so its reason is evident from the
  naming. "Tightened the stability pool's test tolerances" needs no reason: too
  loose is the obvious one. Where the reason is not evident, choose words that
  make it so rather than appending a clause.
- **Crisp, not complete.** Leave out the detail — which functions, which values,
  how. Each change worth recognizing gets named. Write the whole message on one
  line when it fits, even for several changes. Only when it does not fit, write a
  short summary line, a blank line, then a bullet per change: git takes
  everything before the first blank line as the subject.
- **Source changes first.** Test and doc changes made to support a source change
  need no line. A commit that changes only tests or docs says, in a few words,
  what they now check or describe.
- **No rationale.** No "because" or "so that" clauses, no alternatives weighed, no
  evidence that it works ("all tests pass"), no restating the report the message
  sits under.
- **No plan references.** Never name the plan file, its labels, or test names: the
  repos have separate lifecycles.
- **No attribution.** No `Co-Authored-By:` trailer and no "Generated with" line,
  in commit messages or PR descriptions.

The reasoning, the options and the evidence go in the plan file, the PR
description, and the batch report — all read at decision time, with room to
argue.

## Design principles

### Fix, park, or remove files that cause errors or warnings
Any file that causes a compiler error or warning must be dealt with — legacy
config, stale declarations and superseded build setup included — even if it is
"not the file we're working on". The codebase should be clean on every build.
Three outcomes, in order of preference:
1. **Fix it.** The default.
2. **Park it**, when the file still has value that has not been captured yet: its
   replacement is not written, or it holds intent that would be lost. Move it to
   `deprecated/` at the repo root, under its full original path
   (`deprecated/src/minter/Minter_v1.sol`). forge compiles only `src`, `test` and
   `script` and what they import, so nothing there is built, and the kept path
   says where it came from. Do not comment the contents out, and do not leave it
   where it still compiles.
3. **Delete it**, when nothing is left to recover because version control already
   holds the content.

**Whether to park or delete is the user's call, never a unilateral one**: the
judgment is whether the value is already captured, which is theirs to make.
Propose, do not act.

### Generated files are changed only by their generator

### Do it right from the start
Implement code in its intended final location — the right package, file, and
abstraction level — even if it takes longer. Do not put code in a temporary place
intending to move it later: "do it later" defers integration problems rather than
preventing them, and builds structural debt faster than it is paid down. If the
correct final home isn't clear, stop and resolve that before writing code.

### Build shared foundations before the code that depends on them
When work converges many call sites onto a shared abstraction (a common
primitive, library, base, or API), build the abstraction FIRST, then convert the
call sites to it. Doing the call sites first forces each one through an interim
form that was never the target, then demands a second pass: double the edits,
double the review, and a window where the codebase has a shape no one intended.
Building first also pins down the target API, so each call site is written once,
in final form. When a refactor reveals a missing shared piece, do not defer it as
"architecture for later": stop, build it, then do the call sites against it.

The architectural fix is worth far more than the convenience of deferring it:

- **Eradicate, don't contain.** The abstraction exists to make the correct thing
  the path of least resistance. Fix the core *and* convert every existing instance
  to it, and the bad practice that triggered the change almost never recurs. Patch
  the instances and the rotten core remains — it will leak out again.
- **It's now or never.** Deferring the fix dissipates the motivation that surfaced
  it, so "architecture for later" reliably becomes "never". The moment you notice
  the missing abstraction is the moment to build it.
- **Re-weight the human bias against wide refactors.** Human teams avoid wide
  changes because editing every call site by hand is slow and risky. That caution
  comes from human speed, not from good engineering. You can sweep every call
  site reliably in one pass, so default to fixing the core and propagating it
  everywhere, not to layering a fix on a core you know is wrong.

### One code path for default and non-default cases
Do not write one piece of code to set a default value and another to switch to a
non-default one. Every value, the initial one included, flows through one handler
or initializer. A default value appears literally once, in the expression that
composes it — never restated at each early return, where the copies drift apart
silently.

### Never copy values — reference the source
When a value originates elsewhere (a config function, a protocol constant, an
existing variable), call or read that source wherever the value is needed. Do not
read it once and redeclare it as a new constant, hardcode the literal, or create a
duplicate variable under a different name. Copies diverge silently when the
original changes, and they hide the dependency.

### Contract-level state: identity is fine, transient is banned
Holding state on the contract is the basis of object-oriented design, so the rule
is not "no fields": it is about *which* state.
- **Identity state** is what the object *is*: set at construction and constant
  across calls (an owner, a treasury, a salt prefix, a target network). It is
  legitimate and preferred: it states the object's nature once, in its
  constructor, instead of in every signature.
- **Transient state** is what the object is *currently doing*: written by one call
  so a later call can read it. Never do this. Nothing in the signatures tells a
  reader, or the compiler, that call B needs call A to have run first; call them
  in the wrong order and the behavior silently changes. If a function needs
  context, pass it as a parameter or split it into dedicated variants.

The line is whether a field **switches behavior** based on an earlier call. A flag
one function sets to steer another is the banned form, and a boolean is its most
common shape. An append-only ledger that only accumulates a record, and is never
consulted to decide what to do, is not transient state in this sense, but prefer
threading it explicitly while that stays cheap.

When a design seems to force transient state, treat that as evidence the
abstraction is in the wrong place — most often a base class too generic to name
its subclass's argument types. Move the code to where the types can be named and
the arguments thread through normally.

### Do not create a function that has only one use
Inline a function whose only use is its one call site. Being called is one use.
Being tested on its own, being an override seam, and moving code into an external
library to reduce contract size are others.

### Unimplemented functions revert
A function that is not implemented yet must `revert`, not return a plausible stub
value. One that silently returns 0, false, or an empty array looks implemented and
lets tests pass vacuously. Use a descriptive custom error (`error
NotImplemented()`) or `revert("name: not implemented")`.

### Each branch path on its own line
Put each path of a branch on its own line, so coverage tools can tell them apart.
Use curly brackets on every `if`, `for` and `while` (no single-line bodies).
Ternary expressions are fine: formatters already split their branches across
lines.

## Errors and diagnosis

### Never hide a failure; catch only the error you expect
A failure must be visible, and the process must fail clearly. Do not silently
skip or suppress an error. Do not work around an error by hiding it unless the
user explicitly asks for that. Catch only a specific, documented condition, and only when there is a clear reason
it is not a defect: for an optional resource that may legitimately not exist,
catch only its "absent" signal. Every other error propagates unchanged. Never use
a broad catch: a silent fallback makes a broken system look like a working one.

### Error messages report facts, not assumptions
An error message states what was observed, not what the writer guesses caused it.
A check knows that a specific thing failed; it does not know whether the cause is
stale state, a hand-edit, a partial write, corruption, or something unforeseen. A
guess baked into the string outlives the situation it was made for. Report the
facts (which item, which field, which value) and leave the cause analysis to
whoever reads it.

### Diagnose from evidence
Do not use words like "likely", "probably" or "may" to describe a root cause.
Either verify the hypothesis with data (a dry run, a log, a trace) or state
explicitly that it is unverified. Never proceed with a fix based on an unverified
hypothesis.

### Stabilize the error path before fixing the cause
When broken code is discovered, fix it in two separate steps. (1) Stabilize: make
the failure visible and contained — surface it, stop retry loops, ensure one
failure does not cascade — and confirm the error path works before continuing.
(2) Fix the root cause. A system that fails loudly once is far easier to debug and
verify than one that fails silently or repeatedly.

## Naming and comments

### No unexplained abbreviations
Do not use an abbreviation in an identifier or a comment unless it is widely
understood (`ERC20`, `URL`, `id`, `tx`) or defined once at its first use. Do not
coin local shorthand: write `rewardPerShare`, not `RPS`. If a long name genuinely
repeats too often to spell out, define the abbreviation in a comment at its first
occurrence and use it consistently after that.

The short forms of domain nouns used in conversation are never widely understood:
a reader six months later has no glossary. They never appear in code — contract,
library, function and variable names, docstrings and inline comments. Write the
full noun:
- `HY` → `HarborYield`
- `AC` → `AutoCompounder`
- `EQ` → `equivalent`
- `SP` → `StabilityPool`
- `SPM` → `StabilityPoolManager`
- `lev` → `leveraged`
- `col` → `collateral`
- `wcol` / `wcoll` / `wCol` / `wColl` → `wrappedCollateral`

`ERC4626`, `ERC20`, `CR` for collateral ratio where already established, and other
genuinely standard terms remain fine.

### Comments state what stays true
Do not write comments that reference ephemeral or planning artifacts: plan-section
identifiers (`§N`), red/green test-phase labels ("Red:", "Green:"), implementation
states ("buggy:", "TODO after X is merged"), or anything else that becomes stale
once the work is complete. A comment describes intended behavior that is always
true; the rest belongs in the PR or the commit message.

## Solidity contracts

- **Import through the remapped prefix, never a bare path.** Never use
  `"src/..."`, `"script/..."` or `"test/..."` in any Solidity file — contract,
  script or test. Use the prefix of the repo the file lives in: `@harbor/`,
  `@harbor-script/`, `@harbor-test/` for harbor files; `@bao/`, `@bao-script/`,
  `@bao-test/` for bao-base files. Bare paths create duplicate type identities
  when another repo consumes the files as a library, which breaks compilation.
- **Declare errors and events on the interface, not in the contract.** They are
  part of the contract's ABI, so the interface is their one home, shared by the
  implementation, by any delegatecall or helper library that reverts with or emits
  them, and by tests. The contract `is` the interface, so it uses them unqualified;
  a library that imports only the interface writes `IFoo.X` (Solidity ≥0.8.21
  allows emitting an event by its qualified name). A test assertion written as
  `Contract.Error.selector` still compiles.
- **Avoid diamond inheritance when adding functions to interfaces.** A function
  declared on both an interface and a concrete base forces the derived contract to
  override it to resolve the ambiguity. Put the function on one path only: a new
  versioned interface (`IMultipleRewardDistributor_v3`) or the implementation
  itself. Prefer eliminating the diamond over resolving it with overrides.

### UUPS contracts and ownership
- Each UUPS contract composes `Initializable`, `UUPSUpgradeable` and an ownership
  mixin directly. Do not create "Upgradeable" base contracts that bundle them:
  each contract has different initialization needs (roles, reentrancy, custom
  state), and OpenZeppelin's "Upgradeable" suffix already means something else
  (the storage-safe proxy variant).
- Use `HarborOwnable`/`HarborOwnableRoles`, never `BaoOwnable`/`BaoOwnableRoles`.
  They are near drop-in replacements that take an explicit `(deployerOwner,
  pendingOwner)` instead of relying on `msg.sender`. They don't need the
  `UUPSProxyDeployStub`: deploy with `_deployProxyAndRecord`, not
  `_deployProxyViaStubAndRecord`. When a contract on `BaoOwnable` gets a new
  version, it switches to `HarborOwnable`. The two patterns:
  - **HarborOwnable**: `_initializeOwner(deployerOwner, pendingOwner)`.
  - **HarborFixedOwnable**: the owner (the Harbor multisig) is an immutable
    constructor argument, and `_deployProxyAndRecord` gets empty `initData`. For a
    contract whose owner is fixed and which should stay light, such as
    `HarborPauser_v1`.

### Wire related contracts by predicted address
For a related contract deployed at a predictable proxy address, prefer an
immutable constructor argument, its predicted CREATE3 address, over configurable
storage. Do not connect contracts through a setter that can leave the system
half-configured (`minter.updatePriceOracle`): it is a second source of truth that
can drift out of sync. The related
contract can still be upgraded through its own proxy, and the immutable saves
bytecode (no setter, no zero-address check) and gas (no storage read). Use storage
only for an address that genuinely must change independently of upgrades.

**Exception — beacon proxies.** Immutables live in the *implementation's*
bytecode, so every proxy behind one beacon shares them. A per-proxy value (the
`vault` of each `HarborYieldEntry_v1`) lives in per-proxy storage, an ERC-7201
slot or plain storage. Use immutables only for values that are the same for every
proxy, such as the beacon address baked into the factory.

### Contract size never shapes a fix
Design every fix and feature for correctness and clarity alone. A contract's size
is never a reason to choose a fix's form, to place its code somewhere else, to
leave part of it out, or to defer it. Size is a separate problem with its own
remedy (below), solved as its own step. When a correct change takes a contract
over the 24 KB limit, say so in the report and propose the size step separately.
Do not offer the size as an argument for doing the change differently.

### External libraries reduce contract size; internal libraries share code
Two distinct jobs, two distinct tools.
1. **Extract to an EXTERNAL library to reduce contract size.** An external library
   (any `external` or `public` function) deploys separately and is reached by
   `DELEGATECALL`, so its code leaves the calling contract's bytecode. This is the
   only mechanism that reduces a contract's size. **Do NOT extract when the
   extraction would result in more than one external call in a single
   transaction** — code invoked per item in a loop, or from several places in one
   flow, multiplies the call overhead and trades a size problem for a gas one.
   Everything else extracts: a keeper trigger, a governance action or a user
   entrypoint pays one extra call, which is noise beside the token transfers and
   oracle reads already in it.
2. **Use an INTERNAL library ONLY to share code between external libraries and
   contracts.** `internal` functions are inlined into every consumer, so an
   internal library reduces nothing. Its purpose is consistency where inheritance
   cannot reach: one definition compiled into the contract and into each external
   library that needs it. An internal library with a single consumer has no reason
   to exist — fold it into that consumer, or make it external under (1).

Design for these consequences rather than discovering them:
- A shared internal library is duplicated into each consumer's bytecode. That is
  correct — each consumer has its own size budget — but it buys consistency, never
  size. Do not later turn it into an external library: that breaks the reason it
  exists.
- **An external library cannot read the calling contract's immutables.** It shares
  the caller's storage under `DELEGATECALL`, but immutables live in the caller's
  code. Any immutable the extracted code needs must become a parameter — decide
  this when designing the extraction, not when the compiler refuses it.

### Version what is deployed; do not version what is inlined
A library's name says which of the two jobs it does, so a reader can tell without
opening it.
- **An external library is a deployed artifact**: it has an address, it is linked
  into each consumer's bytecode, and swapping it is a deployment event. Version it
  exactly like a contract: `*Manager_v1`, `*_v1`.
- **An internal library is inlined and has no deployed identity.** Name it `*Lib`,
  with no version. A version suffix implies an artifact that can be swapped
  independently, and none exists. It also invites a "which version is deployed?" question that has no
  answer.
- **If a library's visibility changes, its name changes with it**: the name is the
  claim about what it is.
- **Make the name unambiguous across every repo that compiles it.** Solidity
  imports are path-qualified, but the artifact namespace and every tool keyed on
  the bare contract name (`out/<file>.sol/<Contract>.json`, `--match-contract`,
  size, gas and coverage tables, slither) are flat: two repos in one build tree
  cannot both hold a `ValuationLib`. Prefix by domain: `MinterValuationLib`,
  `VaultValuationLib`.

### An ERC-7201 namespace names the STRUCT, so it carries no version
The namespace string derives the storage slot, so it is the only thing that makes
existing data reachable. Version it, and the first upgrade that "updates the name
to match the contract" silently orphans every holder's balance in slots nothing
reads. Use `<project>.storage.<Struct>`: `bao.storage.Minter` is read by
`Minter_v3`, and always will be.
- A struct whose layout must change gains fields at the END, under the same name.
  Appending is the whole point of namespaced storage.
- Storage that genuinely cannot be appended takes a NEW namespace under its own
  name, leaving the old one intact and readable by whatever still owns it. That is
  a second namespace, never a second version of the first.
- **Put `@custom:storage-location erc7201:<ns>` on the STRUCT**, not on the slot
  constant. On the constant it attaches to nothing, and the validator silently
  ignores it.
- **Verify with `yarn validate`, not by hand.** It re-derives every hardcoded slot
  constant from its annotation and compares the two, across every contract at
once. Hand-deriving one
  value with `cast keccak` proves nothing about the annotation agreeing with it.
- **Share the struct with a library by naming it where it is.** Keep the
  annotated struct inside the contract. A library takes it as
  `Minter_v4.MinterStorage storage $`, and the contract passes the pointer in.
  The library and the contract import each other, which compiles. OpenZeppelin's
  upgrade check reads a namespace only from a struct declared in a contract, and
  compares it field by field. So moving the struct out of the contract fails the
  upgrade from the version before, with "Deleted namespace". Wrapping it in a
  single-member struct fails too, with "Deleted `<field>`", although the bytes
  stay where they were. The library is tied to that contract version: the
  contract's next version takes a new version of the library.

## Deploy scripts

### Three layers per contract
1. `deployABC(state, key, ...config...)` — the **orchestrator**: predicts every
   address from salt keys with `_predictAddress`, calls `deployABCImplementation`
   with the resolved addresses, then calls `_deployProxyAndRecord`. Never
   `virtual`; tests call it directly.
2. `deployABCImplementation(state, key, ...resolved-addresses...)` —
   **`virtual`**: receives only fully resolved addresses (never salt keys or config
   objects) and deploys `new ABC(...)`. Tests override it to inject a mock
   implementation without touching the address prediction.
3. `deployABCEntryImplementation()` — **`virtual`**: deploys a sub-contract
   implementation, such as the entry implementation behind a beacon. Tests
   override it to inject a mock sub-contract implementation.

When a contract must bake another contract's address in as an immutable at
construction, split out a `deployABCEntry(state, key)` that deploys the dependency
at a predictable CREATE3 address first. `deployABC` then predicts that address
with `_predictAddress(_key(key, "entrySubkey"))`, with no coupling to deployment
order.

Build salt strings only with FactoryDeployer's `_saltString()`,
`_predictAddress()` and `_key()`, never by hand with `string.concat`. BaoFactory's
CREATE3 gives deterministic addresses from salts, so contracts can reference each
other before they are deployed.

### Deployment config mixins
Each deployment config dimension is a standalone mixin contract whose `virtual`
functions provide useful defaults (`ConfigPriceVolatility_130_stable`,
`ConfigStabilityPool`, `ConfigCollateral_fxUSD_mainnet`). A market's top-level
config (`ConfigMarket_ETH_fxUSD_mainnet`) inherits every relevant mixin and
overrides only what differs. A config value belongs in the mixin that owns its
domain: fee ratios in the volatility config, beside `minterConfig()`; oracle
addresses in the collateral config, beside `wrappedCollateralToken()`. Do not
create a separate mixin for a value that belongs to an existing one: that
fragments the config and forces an override in every market.

## Testing

### Red-green: confirm the test fails before you make it pass
Before any change in behavior — a bugfix, a new feature, or an algorithm change,
in Solidity or in scripts and tooling — write a test that asserts the intended
behavior and run it to confirm it *fails* for the right reason. Then make the
change and run the test again to confirm it passes. Confirming red first proves
the test exercises the change; a test that was green before you touched anything
proves nothing.

When the test can only be written after the code (a new capability has nothing to
assert against until it compiles), get the same proof by breaking the code on
purpose and confirming the test goes red for the right reason. **Fence any such
deliberate break with markers**, so grep finds it and it cannot be left behind:

```
// TEST MODIFICATION BEGIN - MUST BE REVERTED
// <what was changed and which test is expected to go red>
...
// TEST MODIFICATION END
```

Revert it immediately afterwards and confirm `grep -rn "TEST MODIFICATION"` finds
nothing before reporting the work. Never leave a deliberate break in place across
a checkpoint, and never use an unfenced one.

### `test/` is permanent; `script/verify/` is temporary
Where a test lives is decided by how long it lives, not by what it reads.
- **`test/` holds the tests that stay.** `yarn test` and CI run every one, so each
  must be deterministic and repeatable: the same inputs give the same result on
  any machine, any day. A fork PINNED to a block is reproducible and belongs
  there; anything tracking chain HEAD, live prices or current balances is not.
- **`script/verify/` holds the campaigns:** the tests of a deployment, upgrade or
  remediation about to be performed, run by hand before it and retired to
  `deprecated/script/verify/` once it has been. forge runs tests only from its
  test directory, so a plain `forge test --match-path` on a campaign runs nothing
  and exits 0. Run a campaign through `script/verify/run-campaign-test`, which
  points forge at it and fails unless a test ran. A campaign's runner runs every
  test of the campaign, its unit tests first: a test nothing runs is dead.
- **A test that imports campaign code lives with the campaign**, however
  reproducible it is. A permanent test must not depend on temporary code, and the
  campaign's tests retire with it.

This splits upgrade testing in two, and each half is weaker if it tries to be the
other:
- **`test/` proves the upgrade MECHANICS** — that an upgrade can be performed at
  all: the proxy accepts the new implementation, ownership survives, the contract
  is still callable. A hand-built fixture on the previous implementation is the
  right input here, precisely because it is reproducible; it needs no real data.
  So a synthetic previous-version contract is the correct choice, not a weakness.
  Do not move such a fixture onto real forked state to make it "more faithful":
  that moves it to the other half of the split and loses the reproducibility that
  justified its location.
- **`script/verify/` exercises the actual upgrade SCRIPTS** against real state —
  data migration, functional compatibility, whatever only live data can show.
  Non-reproducibility is the point there, not a defect.

**`test/` exists to test PENDING deploys** — the upgrade about to be performed,
not one already made. So there is exactly one upgrade worth testing per contract
at any time: from the version DEPLOYED (check `deployments/*.state.json`) to the
version in SOURCE. If mainnet runs `Foo_v2` and the repo holds `Foo_v3`, the test
is v2→v3. A v1→v2 test re-confirms something that already succeeded and earns
nothing: delete it rather than carry it. When an upgrade ships, retarget the test
to the next step rather than adding another.

### A batch is checked wherever it runs
A deploy, upgrade or remediation that a multisig executes as a Safe batch has
three parts. Each is written once, and nothing restates another.
- **The script builds the batch, and holds no logic of its own.** The `.s.sol`
  file names its inputs and calls a builder in `script/src/`: a read, then a
  build that queues the batch. Tests, campaigns and rehearsals call the same
  builder, so what they check is what the script sends.
- **The checks are written once, in `test/harness/`.** An abstract test contract
  asserts the state after the batch. It reaches that state through one virtual
  seam (harbor's `_afterTheBatch`, `_upgraded`), which by default executes the
  batch on the fork as the multisig would. A check that compares before and
  after reads the before state first, on the fork it starts on. A check of what
  the batch is built from (a refusal, a derived amount) reads the state before
  it, so it is a contract of its own. The checks have three entry points:
  - `test/`: forked at a pinned block before the batch, executed there. CI runs
    it on every change.
  - `script/verify/<campaign>/`: forked at the chain's head, before the batch is
    built.
  - `script/verify/<campaign>-executed/`: a chain where the batch already ran.
    Its seam selects the block after the batch instead of executing. Each batch
    has a window of its own, the block before it and the block after it: one
    window over two batches mixes their effects.
- **The same three commands run a batch on a local node and on mainnet;
  `--local` is the difference.** harbor's:
  1. `script/run-script <Script> --network <net> [--local] --broadcast` deploys
     and saves the batch, and executes nothing: a script run never executes its
     batches. It ends by naming each batch it saved.
  2. The batch is executed by its signer: on mainnet the signers in the Safe app,
     on a local node `script/run-batch <file>`, which sends each call as the
     multisig and prints the window.
  3. `script/verify/run-campaign-test <campaign> <log> --network <net> [--local]
     --window <WINDOW>=<before>:<after>` runs the `-executed` checks. On mainnet
     the window is `n-1:n`, n the block of the Safe's execution.
- **The rehearsal runs those commands, then the checks.** harbor's
  `script/verify/run-rehearsal --network <net> --local` runs, on the local node
  the user started, each script by step 1, each batch it saved by step 2, then
  each `-executed` campaign by step 3 with every window. It starts no node of its
  own, and never reproduces what a script does: a rehearsal that copies a
  script's logic tests the copy. The rehearsal of a sequence of batches names
  their scripts in mainnet order (`script/verify/rehearse-second-genesis`).

A batch built for mainnet can be executed on a local node before the signers
execute it: fork mainnet after step 1 has run there, then run steps 2 and 3 with
`--local` on the mainnet file. After the signers execute it, run step 3 against
mainnet.

### Plan the tests first
Before implementing a new contract or significant feature, add a **test plan** to
the plan file. List each test by function name, state the single behavior it
verifies, and say whether it is a unit test (mock-based, fast) or a fork test
(real mainnet state). The section is complete only when every test in its plan is
written and `yarn test --match-path test/TheContract.t.sol` shows they all pass.

### Tests verify intended behavior; coverage is a check, never the input
A test verifies what the code is *supposed* to do, not merely that lines run. When
asked to improve testing, ask "what is the intended behavior?", then build
scenarios that show the code fulfils that intent. If unsure what a function is
supposed to do, ask: the specification is not in the code. Avoid tests that only
exercise code paths to raise coverage: they reinforce any misunderstanding in the
implementation and give false confidence. Open each test with a short comment
saying what behavior it tests.

When improving a file's tests, do not read the coverage report or the
uncovered-lines list to decide what to write. Work from the source and the
existing tests, list the code's intended behaviors, and write the tests that are
missing. Only then consult coverage, as an independent check that nothing was
overlooked. Tests written off the uncovered-lines list make line X execute instead
of verifying behavior Y: coverage rises, behavior stays unverified, and the report
loses its only value as an ungamed signal of test completeness. Review test
quality by behavior and intent, never by a coverage percentage: high line
coverage routinely hides untested behavior, such as a loop run with one element,
or a revert reached for the wrong reason.

### Assertions
- **Every `expectRevert` asserts a *specific* error, with as many of its arguments
  as possible.** Never use a bare `vm.expectRevert()`: it matches any revert, so
  the test passes even when the revert has an unrelated cause (a setup typo, a
  different guard). Assert the exact custom error or revert string, and pin the
  arguments with `abi.encodeWithSelector(Err.selector, expectedArgs…)` whenever
  they are known and stable. Fall back to the selector alone
  (`vm.expectRevert(Err.selector)`) only for the arguments that are genuinely
  runtime-derived and unpredictable — assert every argument you can compute or
  read.
- **Work out the expected error from the code, never from a trace.** Read the
  function under test, its modifiers, and the libraries and base contracts it
  inherits to find which revert it is *written* to throw — a Solady-based
  `onlyOwner`/`onlyRoles` reverts `Unauthorized()`; an OZ `SafeERC20` call bubbles
  the inner token's revert unchanged — and assert that. Copying the error off a
  `-vvvv` trace enshrines current behavior: a buggy, wrapped or coincidental revert
  passes by construction. Traces are for debugging, not for choosing the
  assertion.
- **Exercise every loop at 0, 1 and N (≥ 2) iterations** — every iteration over a
  dynamic collection: arrays, index-mapped registries, reward-token sets, vault
  lists. A single element hides both the empty path and multi-element bugs
  (off-by-one, accumulation or ordering, swap-and-pop, a residual carried across
  iterations). If a dependency behavior is needed to drive a second iteration (it
  partially fills, so a follow-up pass runs), add that mode to the mock rather than
  skip the N case.
- **Prefer exact assertions (`assertEq`).** When the exact value can be computed
  or read back from the contract, use it — never an approximation. When
  approximation is genuinely required (rounding from integer division in an
  external formula), derive the tolerance from first principles — the maximum
  possible error — and use `assertApproxEqAbs` with that bound and a comment
  giving the derivation. Use `BaoTest.assertApprox(actual, expected, absTolerance,
  relTolerance)` (passes within either bound, as pytest's does) when an absolute
  floor and a relative component are both meaningful, such as when the expected
  value can be zero but a small rounding constant is also possible. Never use a
  percentage tolerance such as `0.01e18` as a blanket fallback.
- **Pin a derived tolerance with `assertDiscriminates` when a concrete adjacent
  wrong value exists.** A tolerance assertion shows `actual` is close to
  `expected`, but not that the bound is tight enough to catch a bug: a later edit
  can widen it past the deviation it was sized to exclude, and nothing fails. When
  the derivation excludes a specific value a plausible bug would produce — the
  ceiling where the code floors (`expected + 1`), a value just past a conservation
  dust cliff, an off-by-one-scaled error — use `BaoTest.assertDiscriminates(actual,
  expected, tolerance, wrongValue, memo)`. It asserts that the band admits `actual`
  and rejects `wrongValue`, turning a one-off "flip the code, watch it go red"
  check into a guard on every run. **Precondition:** it is only satisfiable, and
  only meaningful, when `|wrongValue − expected| > tolerance ≥ |actual −
  expected|` — when the tolerance is the real line between correct and that
  specific wrong value. Do not force it when the legitimate tolerance dwarfs any
  adjacent bug (a large dead-share-dilution bound swamping a sub-wei rounding
  flip). Get the discrimination from a one-sided invariant instead: a conservation
  check (`assertLe(Σparts, whole)`, `assertConserved`) rejects any overshoot,
  whatever the dust bound.

### Mocks
- **A mock matches the real dependency's observable behavior in BOTH directions —
  never stricter, never more permissive.** Add no input validation, zero-address
  or zero-amount guard, allowance check or other error-checking that the real
  dependency lacks: the call would revert *inside the mock*, the test would go
  green, and the real gap would ship. Match the dependency's permissiveness too —
  a Solady-style token's silent transfer to zero, not OpenZeppelin's revert. In
  the other direction, a mock must not implement functions, selectors or behavior
  the real dependency lacks, and must answer calls it does NOT handle as the
  dependency does (success from a permissive fallback; a revert without one).
  Build the mock from the dependency's *real* ABI, verified against the deployed
  contract: a mock built from the calling code's assumption about the ABI can only
  confirm that assumption. (A Curve crypto pool takes `exchange(uint256,…)`, and
  its Vyper `__default__` silently swallows the `int128` form; a mock with the
  `int128` form hid a fund-losing mis-encoding that a faithful mock — uint256-only
  plus a permissive fallback — catches.) Do model the real behavior *modes* the
  code exercises — a Minter that partially fills up to a fee cap, a vault that
  accrues yield — so branches and loops stay reachable. Faithful *behavior*,
  minimal *validation*, exact *ABI surface*.
- **A mock of a UUPS contract is deployable as a proxy implementation.** Give it
  `Initializable`, call `_disableInitializers()` in its constructor, and set its
  state in an `initialize(...)` with the **same signature as the production
  contract's**, not through constructor arguments. The same
  `abi.encodeCall(ProductionContract.initialize, ...)` the deploy script uses then
  works unchanged, and the deploy script places the mock at its predicted address
  with `_deployProxyAndRecord`: the test needs no `ERC1967Proxy`.

### Tests build their setup with the deploy scripts
Tests **use** the deploy scripts' abstract contracts (`HarborYield`, `Swapper`),
and the upstream repo's chain too: harbor-yield's setups take the Minter,
StabilityPool and StabilityPoolManager from harbor's `Deploy_*_Minter`
`deployForPeg`, not a re-implementation. "Use" means compose or inherit, not
specifically Solidity `is`: **compose** (hold one deploy harness per stack) when
independent deploy instances are needed — a separate `FactoryDeployer` state per
run, as for two minter markets on one peg, or to keep harbor and harbor-yield the
separate deploy runs they are in production; **inherit** when one fused instance
is enough.

A `setUp` contains only three kinds of code:
1. **Calls to the real deploy functions, in order** (`deployHarborYieldEntry`,
   then `deployHarborYield`; `deployForPeg`), after `_ensureBaoFactory()` and
   setting the test contract as operator. This exercises the full CREATE3 path.
2. **Mocks installed at the deploy's own seams.**
   - A contract this repo's chain deploys (part of the system under test: the
     vault, its entries, AutoCompounders, an ERC-4626 adapter): override its
     `deploy*Implementation` to return the mock. The deploy script installs it at
     the predicted address in the normal flow; the test does not place it.
   - A separate deployment the system only references by predicted CREATE3
     address (price oracles from harbor-price-aggregators, the shared Swapper):
     `vm.etch` the mock at the address its getter returns (`_swapperAddress()`,
     `_wrappedPriceOracleAddress(...)`, `_equivalentOracleAddress(...)`,
     `_ethPriceOracleAddress(...)`). The getter is a non-overridable pure resolver,
     used by the `.s.sol` deploy to wire the dependency and by the test to know
     where to mock, so the two cannot drift apart: a key change moves both. Etch
     inline in `setUp`, **after** the deploy chain has run, never before: the
     deploy must reference the dependency while its address is still codeless
     (granting it roles, baking it in as an immutable), as production does, and
     the mock needs code only before the first call into it, in the test body.
     `vm.etch` copies code, not storage, so the mock's constructor and field
     initializers do not apply: set its state with its setters, or call
     `initialize` on a UUPS mock. `vm.etch` overwrites whatever is there, so it
     works even where the real contract is already deployed (a CREATE3 install
     would revert on the collision).
3. **Minimal test-actor glue:** fund the test or the owner, grant the test
   contract roles, hold `_predictAddress` handles.

Anything else is reproduced deploy plumbing, and a defect. When you write or
review any `*SetUp` or `Deploy*Test` class, check every line that is not a
deploy-function call or an override against the three kinds. In particular:
- Do not call `_deployProxyAndRecord` by hand, construct a beacon with `new`, or
  repeat logic a `deployABC` function already holds — call the deploy function.
  `new Contract(...)` is only for lightweight fixtures that never need a
  predictable address (token mocks, oracle mocks).
- Do not hand-build a `DeploymentTypes.State{…}` and call `deployX(state)` to place
  a predicted-address dependency: `vm.etch(_swapperAddress(), address(new
  MockSwapper()).code)`, not `deploySwapper(swapperState)`.
- Keep each `vm.etch` and its configuration inline in `setUp`. Do not wrap it in a
  single-use, per-setup `_installMock*At()` helper: it reads worse than the
  visible `vm.etch`, and a `virtual` install hook invites dead overrides. The ban
  is only on the once-per-setup wrapper: a shared install primitive reused across
  many setups (`installContractAt(targetAddress, implementationAddress)`) is fine.
- Never resolve a dependency's address with `vm.mockCall` on a separately derived
  address: when the key changes it silently misses, then reverts "call to
  non-contract". `vm.mockCall`/`vm.mockCallRevert` are only for behavioral
  injection in a single test — forcing one method's return or revert where there
  is no deployment seam.
- Never add test-only fallback logic to a production deploy script.

Keep test-composition primitives — scenario harnesses, `installContractAt`, the
compose blocks — drivable from an external layer, so that a higher-level layer
(such as Python in the wake environment) can compose the same scenarios. Give
them clear, minimal *public* entrypoints, and do not rely on assembly by Solidity
inheritance only. Let this inform small choices: prefer public over internal
where a primitive is a composition seam.

### Tests run in parallel
Forge runs the tests in parallel, in one process, so a test must not change what
another test reads.
- Never create and then remove a file or directory in a test.
- Never call `vm.setEnv` in a test. It changes the variable for every test running
  at the time, in every test file, and nothing can guarantee two tests set the
  same value. Code reads an environment variable through a `virtual` function, and
  a test that needs a value overrides the function (as `Deployer.t.sol`'s
  `BatchWritingDeployer` overrides `_batchDirectory`). To test the function
  itself, leave the variable unset: a `vm.envString` read reverts naming the
  variable (`vm.expectRevert(bytes('vm.envString: environment variable "X" not
  found'))`), and a `vm.envOr` read returns its fallback. `yarn validate` fails on
  a `vm.setEnv` call in a test.
- `./results` holds tracked regression output only: files each run rewrites with
  the same content, so git shows when the content changes. Write such output there
  and leave it. Run logs and other temporary files go to `./tmp`.
- A test that reads back its own output must prove that this run wrote it. The
  tracked copy from an earlier run is always there, so `vm.exists` and a read-back
  prove nothing on their own. Write a marker at the path before the code runs;
  afterwards, assert the marker was replaced.

### `vm.prank` and `vm.expectRevert` bind to the next external call
They bind to whichever EVM call fires first, not to the statement you are looking
at. Argument sub-expressions count: in `vm.expectRevert(...); swap(...,
_expectedOut(x) + 1)` the expectation binds to the external call *inside
`_expectedOut`*, not to `swap`. A test helper that makes setup calls (configure a
route, set a coin) before the call under test steals the binding too.
(`vm.expectEmit`, `vm.expectCall` and `vm.mockCall` do not bind this way: an
intervening call leaves them in place.) Defend structurally, in this order:
- **Hoist** every expression that makes an external call into a local *before* the
  cheatcode, so the guarded statement contains exactly one external call.
- **Split helpers** into a setup function, called before the cheatcode, and a
  single-call function that is the guarded one; document the single-call contract
  on the helper.
- **Never use `vm.prank`.** Always use a `vm.startPrank(addr)` / `vm.stopPrank()`
  pair, which persists across the block so argument evaluation cannot steal the
  prank. Never leave a `startPrank` unclosed.

The failure is silent: the stolen binding usually lands on a view call that
succeeds, so an `expectRevert` test fails with a confusing "next call did not
revert as expected" — or a prank lands on `balanceOf`, and the real call runs as
the test contract.

### Test and script code
- **Call through interface types.** In tests and scripts, call a contract through
  its interface (`IStabilityPool_v3(pool)`), not its concrete type
  (`StabilityPool_v3`), so every call checks that the interface matches the
  implementation. Concrete types are only for construction and deployment.
  - **Declarations:** hold a contract as an `address`, not a typed variable, so
    every call must cast it to the interface it goes through:
    `address rewardToken = address(new MockERC20(...))`.
  - **Calls:** cast to the interface at the call site:
    `IERC20(rewardToken).balanceOf(user)`.
  - **Mock setup:** casting to a concrete type is acceptable for a mock-specific
    function, such as `MockERC20(token).mint()`.
- **In tests, prefer `console.log` over `emit` for debug logging.** It shows in
  `forge test -vvv` output without cluttering the event log (forge-std's
  `console2` is now an alias of `console`). Build readable messages with the `Fmt`
  library and `string.concat`.

## Tools and environment

### Run project scripts with `yarn`
Developers drive the repo through the `yarn` scripts in `package.json` (`yarn
test`, `yarn slither`, `yarn fmt`, `yarn CI`, …). They apply the right config
file, `--filter-paths`, environment and flags; running `forge`, `slither` or
another tool directly misses that setup and can give misleading results. To
verify work or reproduce CI, use the `yarn` script CI uses.

### Dependencies are git submodules, managed with plain git
Dependencies are git submodules in `lib/`. Every one is checked out, and so is
every dependency of a dependency, at every depth. They are managed with git's own
commands, as the cookbook `doc/dependencies.md` gives them, and never with forge's
`install`, `update` or `remove`.
- After a clone, a pull, a merge or a branch switch, `git submodule update --init
  --recursive` puts every folder at the commit recorded for it. Until then the
  build uses the old commits.
- Work on a dependency in its folder under `lib/`, on a branch. After a clone or
  an update a folder is on no branch, and the next update leaves behind a commit
  made there.
- Each clone, and each dependency folder in it, holds three git settings:
  `push.recurseSubmodules check`, `diff.submodule log` and
  `status.submoduleSummary true`. The cookbook gives the commands that write them.
- `submodule.recurse` is set to no value, `false` included. With `true`, a branch
  switch discards an uncommitted edit under `lib/`. With `false`, git can stop
  making the push check.
- `yarn doctor` reports a submodule folder that differs from what this repository
  points to.

The cookbook has the commands for each task, and what can go wrong with each.
`git dep` runs procedures of the cookbook with their checks, and never commits:
`git dep help` lists its commands. `yarn setup`, typed once in a clone, lets git
find it. `yarn doctor --help` gives doctor's full behavior.

### Bash: know what `set -e` misses
Use `set -o pipefail` with `set -e`: without it, a failing pipeline stage other
than the last is ignored. Even with both, bash does not stop when the failing
command is:
- tested — in an `if` or `while` condition, before `&&` or `||`, or after `!` —
  and this includes every command inside a function called that way;
- a command substitution in `local`, `export`, `declare` or `readonly`:
  `local x=$(cmd)` takes the status of `local`;
- inside `$( )` but not its last command, or in a `$( )` used as an argument:
  `echo "$(cmd)"`.

After a critical command, check its exit status explicitly (`$?`, or
`${PIPESTATUS[@]}` for each pipeline stage) rather than relying on `set -e`
alone — always in the cases above. `yarn lint:bash` runs ShellCheck, which reports
some of these (SC2155 for `local x=$(cmd)`).

### Python: import at the top; fix the environment, not the import
Import packages at module top with a plain `import`, relying on the controlled,
pinned environment (the bin uv environment and the Python 3.13 that
`bin/.python-version` pins) to provide them. Do not defer an import into a
function body, add a `try/except ImportError` fallback, or otherwise load a
dependency conditionally so a module can import where the dependency is absent.
That masks the real defect — a module running in the wrong or under-provisioned
environment — and the correct fix is almost always the environment: run the tests
in the same bin environment they test, and pin the interpreter. If a lazy or
conditional import genuinely seems warranted, stop and discuss it before writing
it.

### Never read files likely to hold secrets
Do not read `.env`, `.env.*`, `*.pem`, `*.key`, `credentials*`, `*.secret`,
`id_rsa*` or similar unless the user explicitly asks — not even while
investigating something unrelated, such as resolving a symlink or looking for
shell hooks. Once a tool call reads a secret, it is in the conversation transcript
and must be treated as compromised. For facts *about* such a file (existence,
size, ownership), use `ls -la`, not `cat`. Match the scope of an investigation to
the question asked.
