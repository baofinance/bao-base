# Deployed source baselines

How we know which source produced the bytecode at a deployed address, and what that knowledge lets us
stop doing.

Status: the record and the recovery tool are built and running. The sections marked **PROPOSED** are
designed but not implemented.

## The problem

A deployment manifest says a contract is at an address. It does not say which source produced it, and
it cannot: the manifest is *written by* the deploy, so it is committed after the source it records.

Tags were standing in for the missing fact, and they failed twice over. They were **deleted** — ten of
them, taking 131 baselines with them, and a tag is a ref, so git keeps no record of what it pointed at.
And they were **inaccurate**: measured across ten deploys, three tags marked the commit that recorded
the deploy rather than the commit that built it.

Without that fact, every question about a deployed contract is unanswerable. Which source is running at
this address? Can this file be changed? Can this dependency be updated? The answer to all three was "we
must not touch anything", and the cost was a repository carrying every version of every contract
forever.

## The record

`deployed.json`, at the root of each repository, keyed by `<chainId>/<address>`:

```json
"1/0xd8785d5c51aadeb3ad1d015cd67c8a34dbf58f61": {
  "chainId": 1,
  "chain": "mainnet",
  "address": "0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61",
  "contractType": "BaoPauser_v1",
  "source": "src/BaoPauser_v1.sol",
  "commit": "f3df1931592b7b54c9ffa69f50a6663097955869",
  "commitTimestamp": "2026-03-19T20:50:21Z",
  "deployBlock": 24706244,
  "deployTimestamp": "2026-03-21T13:41:23Z",
  "creationBytecodeKeccak256": "19d60ec0618ee7eaeee3e21e4dd4b2194105acf731ea057cfa575b1f98370c36"
}
```

It is **content, in the tree, in every clone** — which is the first thing tags were not. It is
**append-only**: a baseline is a fact about an immutable artefact, so an edit either corrects a lie or
tells one. And it is **enforceable rather than asserted**, because a baseline naming a commit that does
not build the deployed bytecode fails verification — a hand-edited entry cannot be made to pass.

### Why the chain id and not the chain name

Eight spellings covered four chains across these manifests (`Mainnet`/`mainnet`, `MegaETH`/`megaeth`).
A name is a label anyone can write differently. Keying by id also caught a manifest recording
`chainId: 0` where four others say `4326`, which no amount of name-matching would have noticed.

`chain` sits beside it as a label for reading and as the RPC alias.

### Why the address and not the contract name

The address is the only identity that survives a rename, a move, or a contract changing repositories.
There are four `Aggregator_wBTC_USD_mainnet` at four different addresses — redeployments of one name.

### What is deliberately not recorded

- **No bytecode.** It is derivable from the commit. `creationBytecodeKeccak256` is a hash, which lets a
  rebuild be *verified* without duplicating a fact that can drift.
- **No status, purpose, or liveness.** Whether a deploy is "production" is a property of the *proxy*,
  not of bytecode at an address — the same implementation can back a test proxy and later a real one.
  Liveness comes from the chain's `Upgraded` events, which no deploy script could capture anyway, since
  proxy upgrades are manually-signed Safe transactions.
- **No `deployedAt` copied from the manifest.** harbor's history shows that field repaired twice, so it
  is mutable metadata and a copy could diverge. The chain's own block timestamp is recorded instead.

## Proving a baseline

Four steps, of which only the first is guesswork.

**1. Candidates.** Every commit in the repository, across all refs. Unbounded, and that is a
correction: it was a 120/30-day window, and before that `--limit 12`. Every bound was wrong the same
way — *the error is one-sided*. Too narrow loses the answer and reports it as a miss; too wide costs
only time and cannot give a wrong answer, because every match is verified against the chain and the
"latest at or before the deploy" rule fixes the winner however many were considered.

A time window also measures the calendar rather than the repository: the same 120/30 days gave 89
candidates around February 2026 and 23 around May. Measured cost of removing it: 145 commits carry 89
distinct builds where the window covered 75, at a mean of 1.0s a build — about fourteen seconds.

**2. Locate the source at that commit.** Two identities, because neither survives everything:

- the contract *name* survives a **move** — manifests record the path at deploy time, and files move;
- the recorded *path*, followed through git's rename detection, survives a **rename**, which the name
  cannot by definition.

The name is tried first because the path is the weaker fact. Twelve megaeth aggregators were deployed
as `Aggregator_USDMY_*` and the token was renamed to `USDM` afterwards, so the manifest records a name
that did not exist at the deploy.

**3. Build it.** A worktree at that commit with every submodule placed at that commit's gitlink,
recursively. Two commits reading the same build inputs compile identically, so the work is deduplicated
by a `build_id` — the tree object ids of what a build reads — *per contract*, never globally: a build
only compares the contracts looking at that commit, so recording it as done for everyone silently drops
any contract whose search reaches it later.

**Metadata must be left on.** It was forced off, on the reasoning that the CBOR trailer embeds source
hashes that cannot be expected to agree — true, and irrelevant, because the trailer is stripped from
both sides anyway. What disabling it actually does is change the code *before* it:

```cpp
// ethereum/solidity, libevmasm/Assembly.cpp, in assemble()
if (!m_subs.empty() || !m_data.empty() || !m_auxiliaryData.empty())
    // Append an INVALID here to help tests find miscompilation.
    ret.bytecode.push_back(static_cast<uint8_t>(Instruction::INVALID));
```

The CBOR metadata *is* that auxiliary data, so a contract with no sub-assemblies and no data section
loses the `INVALID` terminator along with it. Measured on `Aggregator_stETH_USD_mainnet`, one source
and one compiler: 3302 bytes with metadata off, 3303 with it on, 3303 deployed. Every contract whose
compiler emits that terminator could never match.

**4. Compare with the chain.** The deployed runtime code against the built one, with the CBOR trailer
stripped from **both** sides — the two trailers never agree, because each hashes the tree it was built
in.

A baseline is recorded only on a match. A candidate that does not match is reported and skipped: an
unrecovered baseline is a known gap, a wrong one is a lie that everything downstream trusts.

### Immutables, and why masking is not good enough — **PROPOSED**

An immutable is written into the runtime code at construction, so the built artefact has zeros where
the chain has values. Today those regions are masked on both sides, which makes the comparison possible
but weakens what it proves: a match is only a match *modulo the immutables*. Two sources differing only
in a value that becomes an immutable would be indistinguishable.

They need not be excluded. These constructors take **no arguments** — everything is hard-coded:

```solidity
constructor() Aggregator_PAXG_USD(PAXG_USD.FEED, PAXG_USD.HEARTBEAT, 1, false) {}
```

so the immutables are fully determined by the source. Executing the creation bytecode reproduces them:
`cast call --rpc-url <chain> --create <creation>` returns the runtime code the constructor would have
produced. Measured on `Aggregator_stETH_USD_mainnet`: 3356 bytes constructed against 3356 deployed,
with the only 39 differing bytes all inside immutable regions — those being the ones that are genuinely
deployment-specific (the UUPS `address(this)`, and a `block.timestamp` capture, which running at the
recorded `deployBlock` would also pin).

So the comparison should *construct and compare*, and mask only what remains deployment-specific,
naming each masked region rather than silently excluding a class of values.

## Invariants

**A baseline's commit must be on a remote.** A stash entry is a real commit that builds like any other,
and searching stashes is worth it — a deploy from a dirty tree that was stashed rather than committed
is findable nowhere else. But a stash is local and never pushed, so recording one names a commit no
colleague and no CI run can resolve, and `git stash drop` destroys it. Stashes are **searched, never
recorded**; a match against one is reported with the fix (commit it, push it, re-run).

**A recorded commit must stay reachable.** A force-push, an orphaning rebase, a migration, or garbage
collection breaks a baseline silently. Two defences: a check that every recorded commit is still on a
remote, and a tag per distinct recorded commit — a tag makes its target reachable, so it is a *pin*,
which is stronger than a check that notices the loss afterwards.

Tags here are **derived from the record and never read as truth**. That is the lesson that started all
this: tags get deleted, files are kept forever. They are regenerable, they give a viewable deployment
list, and if they all vanished tomorrow nothing would be lost but the view.

**Old dependency versions must stay fetchable.** Moving forward freely depends on being able to go
back, and going back needs each recorded baseline's gitlink closure to still resolve.

## Using it

There is one command, with one switch:

- `lib/bao-base/run verify-audit` — **the check**, and what CI runs. It fails if a deployed contract has
  no baseline, if a baseline's recorded source no longer resolves, or if a baseline names a commit no
  remote holds.
- `lib/bao-base/run verify-audit --write` — **the fix**, run when the check fails, the way `fmt` answers
  `fmt --check`.

### After a deploy

1. Deploy as usual. The manifest is written by the deploy script.
2. Commit the source and the manifest.
3. `lib/bao-base/run verify-audit --write` — finds every deployed contract without a baseline, proves
   each against the chain, records what it proved, and creates the tags that name those commits. All
   of it locally: it never pushes.
4. **Push the tags as well as the files** — `git push --tags` alongside the commit that carries
   `deployed.json`. The record and the refs that keep its commits reachable have to arrive together, or
   a fresh checkout resolves neither.

### It only ever looks at this checkout

Nothing in the check asks a remote. In CI the checkout holds exactly what was pushed, so "is this commit
here" already answers "was it pushed", with no network call. On your own machine the same question
answers the weaker "is it in my tree" — so a run can pass locally and fail in CI, and that difference IS
the "you forgot to push" signal. It is the same bargain a formatter makes: it goes green as soon as you
have fixed the file, and the build is what notices you never pushed the fix.

The one exception runs only when something is already failing: if a commit cannot be resolved here, it
asks origin whether a tag names it, so the message can say to fetch rather than send you hunting for
something you have not lost.

### Rebuilding the record

`--write` only ever ADDS. So rebuilding from nothing is not a mode of its own: delete `deployed.json`
and run it again, and every contract is missing, so every one is derived afresh. A single wrong entry is
corrected the same way — delete that entry first. Overwriting in place is the one edit a record of what
is already deployed should never make silently.

### Which repositories this applies to

The presence of `deployed.json` is the switch. A repository holding one is audited by its record; a
repository without one keeps the older comparison against deployment tags. A repository converts by
gaining the file, so this rolls out one repository at a time and none is left unchecked in between.

### When it refuses

- **"on no branch, so nothing will ever push it"** — the match is real but the commit is a stash entry
  or dangling. It is often the *only* source for that deployment. Put it on a branch and push it:
  ```
  git branch deployed/<name> <commit>
  git push origin deployed/<name>
  ```
  Then run again. Do this before anything runs `git stash drop`.
- **"only a local branch has it"** — recorded, but push that branch before pushing the record.
- **"this repository does not have this commit at all"** — a recorded baseline has lost its commit.
  Fetch it from wherever it still exists; if nowhere, that baseline is dead and the deployment has no
  provenance again.
- **"no candidate built what is deployed"** — every commit was tried and none produced that bytecode.
  The source is not in this repository. Do not weaken the comparison to make it pass.

### Reading a baseline

`git show <commit>:<source>` is the deployed source, exactly. `git checkout <commit>` gives the tree it
was built from, submodules included.

## Requirements

These are what the design rests on. Break one and baselines stop being trustworthy, usually silently.

### On deploy tools

1. **Write a manifest entry carrying the address, the contract name, and the chain id.** The address is
   the identity; the chain id is the chain (a name is a label anyone spells differently, and one
   manifest records `chainId: 0`). A recorded `deploymentTime` narrows the block search but is not
   required — the chain's timestamp is authoritative either way.
2. **Never remove a manifest entry.** The contract stays on chain, so removing its entry orphans its
   baseline. harbor dropped eleven live `Minter_v2` entries in one commit.
3. **Do not reuse a contract name for a different artefact within one chain**, or the artefact cannot
   be located unambiguously. Redeployments of the same name at new addresses are fine — the address
   distinguishes them.
4. **Deploy from a committed tree where possible.** A dirty-tree deploy is recoverable only if the
   source is committed and pushed afterwards; if it is stashed and dropped, the provenance is gone.

### On CI

1. **Fail on a baseline whose commit no remote has** — including one on a local branch, because CI is
   checking a record everyone will read.
2. **Fail on an orphaned baseline** — a record whose manifest entry was removed.
3. **Fail on a recorded commit this repository no longer holds.**
4. **Verify `deployed.json` is on the default branch.** A record living only on a feature branch is not
   the repository's record.
5. **Re-verify that each recorded commit still builds the recorded bytecode.** This is the check that
   makes the record enforceable rather than asserted, and the one that would have caught both defects
   found while building it. Expensive; sample or run on change if a full pass is too slow.
6. **Do not delete tags** (see below), and enable tag protection on the pattern the record generates.
7. **Report unrecovered contracts, never fail on them.** Every repository starts with all of them, and a
   check that is red for the length of a migration is one people learn to skip.

### On the repository

1. **Recorded commits must stay reachable.** No force-push that orphans one, no history rewrite that
   drops one. A tag per recorded commit turns this from a hope into a pin.
2. **Old dependency versions must stay fetchable**, because going back is what makes moving forward
   free.

## What it frees us from

Each of these was previously impossible for one reason: **the repository was the only record of what
was deployed**, so nothing in it could change. That is no longer true, and the consequences are larger
than the record itself.

### Versioned contracts

`Foo_v1`, `Foo_v2`, `Foo_v3` side by side, forever. They exist because the tree had to keep every
deployed implementation compilable — tests referenced them, and deleting one destroyed the only copy of
what was running on chain.

Now the tree keeps **one** `Foo`. Development continues in the same file; a reference to a deployed
version is a fork or a `vm.etch`, and the source is `git show <commit>:<path>` away.

This does **not** free any contract's 24KB budget — that is per-contract runtime size and unrelated.
What it cuts is everything scaling with file count: compile time, artefact count, test and coverage and
slither runtime, reviewer load, and the flat-namespace collision surface, which is not cosmetic here —
the aggregators already carry twelve clashing contract names, and a clash is exactly what makes an
artefact impossible to locate unambiguously.

### Compatibility layers

The shims that exist so old code still compiles against new dependencies: forked copies of upgraded
library files, interfaces re-declared to match two versions at once, `_v2`/`_v3` interface hierarchies
carrying a diamond nobody wants. Every one is scaffolding holding up code that only needs to compile
because the tree is doubling as the deployment record.

`Token.sol` is the concrete case, and it is the first decision the record discharged. Its errors are
duplicated into `IToken` deliberately, documented in its own header: it "is inlined into contracts that
are already deployed and audited, so its source has to stay byte-for-byte reproducible". That is a
compatibility constraint imposed purely by the record-keeping role, and the duplicate it forces is what
breaks interface generation. With the record in place the file can simply be corrected.

### Dependency updates

The current pattern is that a dependency bump has to keep every previously deployed contract compiling,
so the bump drags a compatibility shim behind it — or does not happen.

Old code is now rebuilt **against the dependency versions it was deployed with**, taken from that
commit's gitlinks, so today's tree owes it nothing. A bump only has to satisfy the code being developed
now.

The one obligation this creates is the mirror: moving forward freely depends on being able to go back,
and going back needs each recorded baseline's gitlink closure to still resolve.

### And directly

- **Debug at the commit.** Check out what was deployed, exactly, submodules included, and step through
  it.
- **Audit hand-off without tags.** The record names the commit and proves it against the chain, which
  is more than a tag ever asserted.
- **Generated interfaces — PROPOSED.** `cast interface` emits a Solidity interface from an artefact's
  ABI, structs and errors included. Generating one per deployed contract, plus an accessor that casts
  its recorded address, decouples *the shape of what is deployed* from *the shape we are developing
  towards* — the two are currently fused into one hand-written interface, so editing it for new work
  silently changes what tests claim about a deployed contract.

  Three wrinkles, all measured: feed it the **ABI alone**, because externally-linked contracts fail with
  `expected bytecode, found unlinked bytecode with placeholder`; **dedupe by full signature**, because a
  contract that both inherits an interface and imports a library declaring the same errors gets two
  identical ABI entries and the generated Solidity will not compile; and **name** the interface, because
  it emits `interface Interface`.

  The risk to manage: decoupling removes a compatibility check you currently get by accident. Keep at
  least one test casting a live deployment to the *current* interface.

## What must not be assumed

- **The ABI carries no provenance.** Once solc emits it, nothing says which declaration came from which
  file, so a generator cannot prefer one source over another. Deduping by signature is mechanical and
  sound; anything phrased as "prefer the interface" is unimplementable at that layer.
- **Bytecode equality with immutables masked does not distinguish siblings.** See above.
- **The manifest's `deploymentTime` is the deploy script's clock**, written after the broadcast: 2m55s
  late for `BaoPauser_v1`, and shared across a whole batch of aggregators deployed at different moments.
  It is used only as an upper bound; the chain's block timestamp is authoritative.

## Testing the tool

The tool is proved by **constructed scenarios, not by running it against this repository**. A repo that
happens to exercise a case today may stop doing so tomorrow, and a case it has never contained is one
the tool has never been shown to handle. Every scenario below is a fixture:

a file that moved; a contract that was renamed; both at once; a deploy from a tree behind the tip; a
deploy from an uncommitted tree whose source landed afterwards; a commit only a stash holds; a commit no
remote holds; two manifests describing one address; two manifests disagreeing; a manifest with no chain
id; an entry with no address; an entry with no deployment time; two files declaring one contract name;
two contracts whose bytecode differs only inside immutables; a build that fails; a submodule that cannot
be placed; a compiler that emits the `INVALID` terminator and one that does not.

## Rollout

Per repository, and the presence of `deployed.json` is the switch: while it is absent the tag-based
comparison stands, and once it exists the record governs. bao-base first (one contract, proved by
hand), then harbor-price-aggregators, then harbor, harbor-yield, harbor-swap.
