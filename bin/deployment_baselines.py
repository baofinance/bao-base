#!/usr/bin/env python3
"""`deployed.json` — the commit each deployed contract was built from.

A manifest says a contract is at an address. It does not say which source produced it, and it cannot:
the manifest is WRITTEN BY the deploy, so it is committed after the source it records, and the tags
that were standing in for the missing fact turned out to mark the state commit rather than the source
commit for three of ten measured deploys.

So the baseline lives here instead - as content, in the tree, in every clone, keyed by the address,
which is the only identity that survives a rename, a move, or a contract changing repositories. A tag
is a ref: delete it and git keeps no record, which is how ten of them took 131 baselines with them.

APPEND-ONLY, and the reason is not immutability for its own sake. A baseline is a fact about an
immutable artefact - the bytecode at that address will never change - so an edit either corrects a lie
or tells one. Growth is expected; edits are not. The CHAIN is what makes this enforceable rather than
merely asserted: a baseline naming a commit that does not compile to the deployed bytecode fails
anchoring, so a hand-edited entry cannot be made to pass.

WHAT IS DELIBERATELY NOT HERE. No status, no purpose, no liveness. Whether a deploy was "production"
or "test" is a property of the PROXY, not of bytecode at an address - the same implementation can be
attached to a test proxy and later to a production one. Liveness is derived from the chain's
`Upgraded` events, which no script could capture anyway, since proxy upgrades are manually-signed Safe
transactions. A baseline carries facts about an artefact and no judgements about it.
"""

from __future__ import annotations

import json
import subprocess
from collections.abc import Iterable
from dataclasses import asdict, dataclass, fields, replace
from pathlib import Path

from deployment_recovery import declared_in
from deployment_records import Entry, Problem, normalise, read_records

SCHEMA_VERSION = 1
RECORD = "deployed.json"


class UnknownSchema(Exception):
    """The record was written by a version this does not understand.

    Raised rather than tolerated: every manifest in the fleet carries `schemaVersion: 1` and nothing
    reads it, which makes the field decoration. A version that is asserted is what makes changing the
    schema later safe, because an old reader stops instead of misreading."""


class Conflict(Exception):
    """A baseline already exists for this address, saying something different. Never resolved here -
    which of the two is true is a question about the chain, not about a file."""


# A field is named ONCE, by the dataclass below, and that name is the file's name. The file is
# camelCase because every manifest in the fleet already is (`contractSource`, `contractType`,
# `deploymentTime`, `chainId`) and a reader moving between them should not have to translate. The
# first draft carried a table of Python name to file name instead; every one of its fourteen rows was
# the mechanical snake-to-camel of the field beside it, so it stated the field list a second time and
# said nothing - a second place to forget a field. `Entry`, which mirrors the manifests rather than
# this file, keeps Python spelling: the two are different objects and only this one IS the record.


@dataclass(frozen=True)
class Baseline:
    """One deployed contract's source, as a fact.

    `contractType` duplicates the manifest's field of that name, deliberately and under the same
    spelling: it is what makes the record readable on its own, it cannot drift because both are
    write-once facts about one immutable artefact, and calling it something else would invite the
    question of whether it means something else. `deployedAt` is NOT duplicated, for the opposite
    reason - harbor's history shows it repaired twice (a null filled in, a date reformatted), so it is
    mutable metadata and copying it would be a copy that can diverge.


    Every timestamp is UTC, written with a `Z`. Both come from Unix seconds - the block's own, and
    `git log --format=%ct` - rather than from any formatter that carries a local offset, so a record
    does not depend on where the person recovering it was sitting.

    `commitTimestamp` beside `deployTimestamp` is diagnostic, not decoration: a commit made AFTER
    the deploy proves the deploy ran from a tree that was not committed yet, which is the ambiguity
    the tags could never settle. And `deployTimestamp` is the CHAIN's, where the manifests record the
    deploy script's clock - measured 2m55s late for BaoPauser, and shared across a whole batch of
    aggregators that were deployed at different moments."""

    chainId: int  # the chain. `chain` beside it is a label for reading and for the RPC alias
    chain: str
    address: str
    contractType: str
    source: str  # normalised and repo-qualified, resolvable at `commit`
    # Which manifest CLAIMED this deployment. Recovery knew it and threw it away, and without it
    # "is every contract this state file records now recorded" is a hand classification rather than a
    # query - which is what a deploy revision's coverage has to be before its tag check can retire. It
    # also derives the deploy tag: `deployments/<chain>/<file>.json` names `deploy/<chain>/<file>`.
    #
    # PLURAL, because 44 of the aggregators' addresses are in two manifests, and recording one of them
    # would be the arbitrary pick the merge refuses to make everywhere else. A list rather than a tuple
    # because `add` compares baselines whole, and a tuple read back from JSON is a list - which would
    # make a re-run of the same fact look like a conflicting one.
    stateFiles: list[str]
    commit: str
    commitTimestamp: str
    deployBlock: int
    deployTimestamp: str
    # The algorithm is in the NAME, not smuggled into the value as a prefix: a reader checking it runs
    # `cast keccak` and compares, with nothing to strip first.
    creationBytecodeKeccak256: str
    # What the commit alone does not settle, and every baseline carries. The compiler comes from the
    # pragma and whatever versions a machine has installed; the settings come from one forge release's
    # reading of that commit's foundry.toml. Both move under the record's feet - one deployed
    # contract's explorer record says `prague` where a rebuild here chose `osaka`, and both build the
    # deployed code - so a proof states what it was proved with.
    compiler: str
    # solc's own settings, minus `compilationTarget`, which is `source` and `contractType` said twice.
    settings: dict[str, object]
    # The closure the build read, each source as its git blob id, and the repository each blob lives
    # in: a blob id resolves only in the object store that holds it, and most of these are submodules.
    sources: dict[str, str]
    submodules: dict[str, str]


def key(chain_id: int, address: str) -> str:
    """The identity of a deployed contract, as one string.

    The chain is its ID, not a name: eight spellings covered four chains across these manifests
    (`Mainnet`/`mainnet`, `MegaETH`/`megaeth`), and a name is a label anyone can write differently. The
    id also caught a manifest recording `chainId: 0` for MegaETH where four others say 4326 - a defect
    no amount of name-matching would have seen.

    The address is lowercased because manifests checksum it, and two spellings of one address would
    otherwise become two baselines for one artefact."""
    return f"{chain_id}/{address.lower()}"


def tag_names(state_files: Iterable[str], commit: str) -> list[str]:
    """The tag each state file wants for this commit: `deploy/<chain>/<file>@<commit>`.

    DERIVED, not agreed. A state file lives at `deployments/<chain>/<file>.json`, so the tag is that
    path with the directory and the suffix removed - which makes "does this tag match the record"
    string equality rather than a naming convention someone has to keep, and puts the chain in the name
    for free.

    One per state file, because a commit serves several: 25 such pairs across the aggregators' twelve
    recorded commits, since 44 of their addresses are described by two manifests. Naming the commit
    alone would need something to CHOOSE which file names it.

    `<commit>` cannot be a path segment - `refs/tags/deploy/mainnet/v4-oracles` as a file blocks any
    directory of that name, so `deploy/mainnet/v4-oracles/abc123` cannot be created beside it. `@`
    keeps the relation inside the last segment, where it can."""
    return sorted(
        f"deploy/{path.removeprefix('deployments/').removesuffix('.json')}@{commit[:10]}" for path in state_files
    )


def deploy_tags(baseline: Baseline) -> list[str]:
    """The tags this baseline's commit wants, one per state file that claimed the deployment."""
    return tag_names(baseline.stateFiles, baseline.commit)


def create_missing_tags(repo_root: Path, baselines: Iterable[Baseline]) -> tuple[list[str], list[tuple[str, str]]]:
    """Create, LOCALLY, the tag each recorded commit wants and has not got. Never pushes.

    Part of the repair rather than advice printed for someone to retype: a checklist of `git tag` lines
    is a repair the reader has to perform by hand, and the names are derived from the record anyway.

    Pushing is deliberately NOT done here. The record and its tags are written together on the machine
    that made them, and what leaves that machine stays one decision the user makes knowingly - the same
    way this writes `deployed.json` without committing it.

    "Has not got" is ANY tag pointing at the commit, matching what `Review.untagged` asks. A commit some
    other convention already names is preserved, and imposing a second name on it would be a naming
    policy nobody asked for.

    Returns what it created AND what it could not, because `git tag` fails for reasons that matter: the
    commit is absent from a shallow checkout, the derived name is already taken by a different commit,
    refs are read-only. Swallowing those would leave the record written, the commits unpreserved, and
    the check still red with nothing anywhere saying why."""
    created: list[str] = []
    failed: list[tuple[str, str]] = []
    for baseline in baselines:
        named = subprocess.run(
            ["git", "tag", "--points-at", baseline.commit], cwd=repo_root, capture_output=True, text=True
        ).stdout.strip()
        if named:
            continue
        for tag in deploy_tags(baseline):
            done = subprocess.run(["git", "tag", tag, baseline.commit], cwd=repo_root, capture_output=True, text=True)
            if done.returncode == 0:
                created.append(tag)
                continue
            said = (done.stderr or done.stdout or "").strip()
            failed.append((tag, said.splitlines()[-1] if said else f"git tag exited {done.returncode}"))
    return sorted(created), sorted(failed)


def reached_by(repo_root: Path, commit: str) -> list[str]:
    """Every ref that reaches `commit` - branches first, then tags.

    "Push that branch" without saying WHICH is a remedy the reader has to go and derive, and the answer
    was already in hand: `commit_reach` runs these very queries and keeps only whether the output was
    empty. Every one is named rather than the first, because naming one of several would send someone
    to push a branch they did not mean."""
    return _contains(repo_root, "branch", commit) + _contains(repo_root, "tag", commit)


def remote_tags(repo_root: Path) -> dict[str, str]:
    """Every tag the REMOTE has, name to commit. Empty when no remote answers.

    Git has no remote namespace for tags. A remote BRANCH is visible locally as `refs/remotes/origin/…`,
    but a fetched tag and a local-only tag are the same object in `refs/tags/` - so whether everybody
    else can resolve a tagged commit can only be settled by asking. `verify-audit` already fetches tags
    at startup for exactly this reason: "whether the local tag list is stale cannot be answered locally".

    An annotated tag is listed twice, the `^{}` line carrying the commit it dereferences to, and it comes
    second - so the later line wins and the map holds commits rather than tag objects."""
    listed = subprocess.run(["git", "ls-remote", "--tags", "origin"], cwd=repo_root, capture_output=True, text=True)
    found: dict[str, str] = {}
    for line in listed.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        name = ref.removeprefix("refs/tags/").removesuffix("^{}")
        if name:
            found[name] = sha
    return found


def commit_reach(repo_root: Path, commit: str) -> str:
    """Where a commit lives in THIS checkout, which decides whether a baseline may name it.

    Purely local, and deliberately so: nothing here asks a remote. In CI the checkout holds exactly
    what was pushed, so "is it here" already answers "was it pushed" - with no network call, and with
    the tool needing no opinion about what anybody else can resolve. On a developer's machine the same
    question answers the weaker "is it in my tree", and CI is what catches the difference. That is the
    same bargain a formatter makes: it passes locally once you have fixed the file, and the build is
    what notices you never pushed it.

    Three answers:

    - `"reachable"` - a branch or a tag here contains it, so this checkout can resolve it.
    - `"none"` - the object is here, but no ref reaches it: a stash entry, or a dangling commit. NEVER
      recordable. `git push` pushes refs, so nothing will ever carry it anywhere, and `git stash drop`
      destroys it - a downstream check is no safety net when the object can be gone before it runs.
    - `"absent"` - this repository does not have the commit at all. A force-push, an orphaning rebase,
      or garbage collection, leaving a baseline pointing at nothing. Distinguished from `"none"`
      because the remedy differs: fetch it, or the baseline is dead."""
    known = subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=repo_root, capture_output=True, text=True
    )
    if known.returncode != 0:
        return "absent"
    # A tag counts as well as a branch. It is the better ref for the job - it does not move and is not
    # deleted in the ordinary course of work - but either means this checkout can resolve the commit.
    if _contains(repo_root, "branch", commit) or _contains(repo_root, "tag", commit):
        return "reachable"
    return "none"


def _contains(repo_root: Path, kind: str, commit: str, *scope: str) -> list[str]:
    """The branches or tags reaching `commit`, by name. Empty when none do, or the question failed."""
    listed = subprocess.run(["git", kind, *scope, "--contains", commit], cwd=repo_root, capture_output=True, text=True)
    if listed.returncode != 0:
        return []
    return [line.lstrip("* ").strip() for line in listed.stdout.splitlines() if line.strip()]


def read_baselines(repo_root: Path) -> dict[str, Baseline]:
    """Every baseline this repository records, keyed by `key`. Absent file means none recorded yet -
    which is the ordinary state of a repo that has not started, not an error."""
    path = repo_root / RECORD
    if not path.is_file():
        return {}
    document = json.loads(path.read_text())
    version = document.get("schemaVersion")
    if version != SCHEMA_VERSION:
        raise UnknownSchema(f"{RECORD} declares schemaVersion {version!r}; this reads {SCHEMA_VERSION}")
    # Every field by name, and a field the record does not carry raises rather than defaulting: a
    # baseline that cannot say what built it is the gap this record exists to close, so it is not
    # readable as one that merely omits it.
    return {
        entry_key: Baseline(**{field.name: written[field.name] for field in fields(Baseline)})
        for entry_key, written in (document.get("baselines") or {}).items()
    }


def add(baselines: dict[str, Baseline], baseline: Baseline) -> dict[str, Baseline]:
    """`baselines` with `baseline` added. Idempotent, and refuses to replace.

    Re-recording the same fact is a no-op, so a deploy re-run or a recovery pass that covers ground it
    already covered is safe. Recording something DIFFERENT for an address that already has a baseline
    is refused: the artefact at that address never changed, so the two claims cannot both be true and
    this is not the place to decide which is."""
    entry_key = key(baseline.chainId, baseline.address)
    existing = baselines.get(entry_key)
    if existing is not None and existing != baseline:
        raise Conflict(
            f"{entry_key} is already recorded as {existing.contractType} from {existing.commit[:10]}; "
            f"refusing to replace it with {baseline.contractType} from {baseline.commit[:10]}"
        )
    return {**baselines, entry_key: baseline}


def write_baselines(repo_root: Path, baselines: dict[str, Baseline]) -> None:
    """Write the record, sorted by key.

    Sorted so that two deploys racing collide as two disjoint ADDITIONS a human can resolve by eye,
    rather than as a reordering of the whole file. A trailing newline because every other file in the
    tree has one and a diff that says "no newline at end of file" wastes a reader's attention.

    Written through a temporary file and renamed, because callers write it REPEATEDLY - a recovery run
    saves after each contract it verifies, so a run over 85 of them that is interrupted keeps what it
    proved rather than losing all of it. A rename is atomic, so an interrupted write leaves the
    previous complete file rather than half of the new one."""
    document = {
        "schemaVersion": SCHEMA_VERSION,
        # `asdict` IS the file's shape: a field is named once, and that name serves both sides.
        "baselines": {entry_key: asdict(baselines[entry_key]) for entry_key in sorted(baselines)},
    }
    final = repo_root / RECORD
    pending = final.with_suffix(final.suffix + ".pending")
    pending.write_text(json.dumps(document, indent=2) + "\n")
    pending.replace(final)


# ── reviewing: what the manifests say against what the record holds ────────────────────────────────


@dataclass(frozen=True)
class Review:
    """What a repository's manifests and its record say about each other."""

    recorded: list[Baseline]  # a baseline whose contract a manifest still names
    unrecovered: list[Entry]  # deployed, with no baseline yet
    unreadable: list[Problem]  # a manifest path that cannot be normalised
    orphaned: list[Baseline]  # a baseline for an address no manifest mentions any more
    conflicts: list[Problem]  # two manifests describing one address differently, one row per address
    # (baseline, reach) for every recorded commit THIS checkout cannot resolve — see `commit_reach`.
    # The reach is carried rather than a boolean because the remedy differs: a commit on no ref has to
    # be put on one, and an absent commit has to be fetched. In CI the checkout holds only what was
    # pushed, so this is also what catches a record pushed without the commits it names.
    unreachable: list[tuple[Baseline, str]]
    # (baseline, the recorded inputs that no longer resolve). The record names every source by its git
    # BLOB at the commit that built it, so this asks whether that commit still holds those exact bytes.
    inputs_missing: list[tuple[Baseline, list[str]]]
    # (baseline, the inputs this clone cannot look at) - inside a submodule it does not hold. Separate
    # from missing because a partial checkout is not a defect, and failing on it would fail every
    # developer's build for a clone only CI makes.
    inputs_unchecked: list[tuple[Baseline, list[str]]]
    # Baselines whose commit NO TAG points at. A branch holding it is not preservation: branches move,
    # are force-pushed and are deleted when work merges, where a tag does none of those. Any tag counts,
    # not only the `deploy/…` name `deploy_tags` would generate - preservation is the job here, and
    # failing a repository that tags by another convention would impose a naming policy nobody asked
    # for. The NAME matters for the other job, naming a state file's capture, which is what the
    # suggested tag is for.
    untagged: list[Baseline]
    # (baseline, what its source actually declares) where the two disagree, `None` when the source
    # declares no single contract. A deployment record is a record of a DEPLOYMENT, so its contract
    # name is the name at deploy time and the source at that commit declares exactly that. Twelve of
    # the aggregators' eighty-three disagree, every one a rewrite after a rename.
    misnamed: list[tuple[Baseline, str | None]]


def drop(pending: dict[str, object], account: list[Problem], entry_key: str, entry: Entry, reason: str) -> None:
    """Take a contract out of a run and record why, in ONE call so neither can happen without the other.

    Every stage of a recovery narrows what is still being looked for - an entry that cannot be keyed, a
    chain that will not answer for an address, a screen no constructor bears out - and each narrowing was
    two statements: remove it, then append a row. A `continue` between them is all it takes for a contract
    to leave without a trace, which is what happened to both mainnet BTC aggregators: they left on a
    screen and were reported as though nothing in the repository had built them.

    `entry_key` need not be in `pending`. The stages BEFORE the search have nothing to remove, and they
    are exactly the ones whose reasons were reduced to a count at the top of the run - so one call serves
    both, and there is no second way to record a drop that could fall out of step with this one."""
    pending.pop(entry_key, None)
    account.append(Problem(entry, reason))


def _inputs_gone(
    repo_root: Path, baselines: list[Baseline]
) -> tuple[list[tuple[Baseline, list[str]]], list[tuple[Baseline, list[str]]]]:
    """Which recorded inputs no longer resolve, and which this clone cannot look at.

    `creationBytecodeKeccak256` states that these inputs produce that bytecode, and nothing has ever
    asked again. Rebuilding to check costs minutes; this asks the cheap half of the same question - are
    the INPUTS still what was built - and with the compiler and the settings pinned in the record, and
    solc deterministic, identical inputs mean identical output.

    It asks the STRONG form: does this path at this commit still hold these bytes. Whether the blob
    exists somewhere is a weaker question that a rewritten history passes, because the object survives
    in the odb while the tree at that commit says something else.

    A source inside a submodule is resolved against the gitlink THE RECORD holds for it, never the
    submodule's tip - the same routing that wrote the blob ids, so the question matches the answer.

    One `git cat-file` per holding repository, not per source: eighty-three baselines naming thirty-two
    sources each is two and a half thousand lookups, asked as about thirty."""
    unchecked_by: dict[int, list[str]] = {}
    by_holder: dict[Path, list[tuple[int, str, str, str]]] = {}
    for index, baseline in enumerate(baselines):
        for path, blob in sorted(baseline.sources.items()):
            # The longest match, so a file in a nested submodule is read against the nested gitlink.
            prefix = max((p for p in baseline.submodules if path.startswith(f"{p}/")), key=len, default=None)
            holder = repo_root if prefix is None else repo_root / prefix
            at = baseline.commit if prefix is None else baseline.submodules[prefix]
            inside = path if prefix is None else path[len(prefix) + 1 :]
            if prefix is not None and not (holder / ".git").exists():
                unchecked_by.setdefault(index, []).append(path)
                continue
            by_holder.setdefault(holder, []).append((index, path, f"{at}:{inside}", blob))
        for path, gitlink in sorted(baseline.submodules.items()):
            # Only a submodule some recorded source lives in. A baseline names thirty-two gitlinks and
            # compiles from three of them; the rest are pins of dependencies the build never read, and
            # the aggregators hold three that are not even checked out - so checking all of them warns
            # on every build about something nobody can act on. What reproduces the bytecode is the
            # SOURCES plus the pinned compiler and settings, so a submodule that supplied none of them
            # cannot change the answer, which recovery demonstrates by building while reporting exactly
            # those three unplaced.
            if not any(source.startswith(f"{path}/") for source in baseline.sources):
                continue
            holder = repo_root / path
            if not (holder / ".git").exists():
                unchecked_by.setdefault(index, []).append(path)
                continue
            by_holder.setdefault(holder, []).append((index, path, gitlink, gitlink))

    missing_by: dict[int, list[str]] = {}
    for holder, asked in by_holder.items():
        answered = subprocess.run(
            ["git", "cat-file", "--batch-check"],
            cwd=holder,
            input="\n".join(expression for _, _, expression, _ in asked) + "\n",
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        for position, (index, path, _, expected) in enumerate(asked):
            # An unanswered line is counted as missing rather than skipped: `--batch-check` answers one
            # line per input, so a short read means something is wrong, and passing it would be silent.
            said = answered[position] if position < len(answered) else "missing"
            if said.endswith(" missing") or said.split()[0] != expected:
                missing_by.setdefault(index, []).append(path)

    return (
        [(baselines[index], paths) for index, paths in sorted(missing_by.items())],
        [(baselines[index], paths) for index, paths in sorted(unchecked_by.items())],
    )


def review(repo_root: Path, *, ignoring_the_record: bool = False) -> Review:
    """Compare every deployed contract a repository records against the baselines it holds.

    ORPHANED is the one with teeth, and it is why this can enforce "an entry is never removed" without
    reading git history: deleting a manifest entry leaves its baseline pointing at a contract nothing
    claims any more. harbor did exactly that - eleven `Minter_v2` implementations dropped in one commit
    when they were redeployed, still on chain, and nothing in the file says what built them. Once a
    baseline exists, that deletion cannot happen quietly again.

    UNRECOVERED is a backlog, not a fault. Every repository starts with all of them, so failing on it
    would make the check red on the day it lands and red for as long as the backlog takes - which is
    how a check stops being read. It is reported and counted instead."""
    entries, unreadable = normalise(read_records(repo_root), repo_root)
    # A deployed contract IS a chain and an address, so an entry missing either cannot be keyed - and
    # an entry that cannot be keyed would silently vanish from every count, which is the failure this
    # whole model exists to remove. Both gaps are real in one file: `megaeth/v4-oracles.json` records
    # `chainId: 0` where four other manifests say 4326, and carries five entries whose `address` is an
    # empty string beside the deployed ones.
    unreadable = list(unreadable)
    identified: list[Entry] = []
    for entry in entries:
        if not entry.chain_id:
            unreadable.append(
                Problem(entry, f"chainId is {entry.recorded_chain_id!r}, so the chain cannot be identified")
            )
        elif not entry.address:
            unreadable.append(Problem(entry, "the record gives no address, so the contract cannot be identified"))
        else:
            identified.append(entry)
    # `ignoring_the_record` is what REGENERATION is: the manifests read as if nothing were recorded, so
    # every identified contract is a candidate again. It must not merely discard the record after
    # reading it - a mode whose purpose is replacing an unreadable record cannot begin by parsing one -
    # so the read does not happen at all, and every question below that asks about baselines answers
    # empty by itself.
    baselines = {} if ignoring_the_record else read_baselines(repo_root)
    claimed = {key(e.chain_id, e.address) for e in identified}
    # Over EVERY identified entry, not only the unrecorded ones. Merging just the ones without a baseline
    # meant a disagreement about a RECORDED address was never computed, so a complete record drove the
    # count to zero - and zero read as health. What the manifests say about each other cannot depend on
    # how much of the record happens to be filled in.
    merged, conflicts = _by_address(identified)
    unrecovered = [entry for entry in merged if key(entry.chain_id, entry.address) not in baselines]
    # Asked once per distinct COMMIT, not once per baseline: twelve commits carry the aggregators'
    # eighty-three records, so this is twelve `--contains` calls rather than eighty-three. Every one of
    # them local - a review touches no remote at all.
    reaches = {commit: commit_reach(repo_root, commit) for commit in {b.commit for b in baselines.values()}}
    # `--points-at`, not `--contains`: a commit some later tag happens to contain is safe from
    # collection but is not NAMED by it, and asked once per distinct commit rather than per baseline.
    named = {
        commit: bool(
            subprocess.run(
                ["git", "tag", "--points-at", commit], cwd=repo_root, capture_output=True, text=True
            ).stdout.strip()
        )
        for commit in {b.commit for b in baselines.values()}
    }
    # Only where the commit is present, for the reason `misnamed` gives below: a baseline whose commit
    # this repository has lost would report every one of its sources as missing too, sending the reader
    # after thirty-two files when the finding is one lost commit.
    inputs_missing, inputs_unchecked = _inputs_gone(
        repo_root, [baselines[k] for k in sorted(baselines) if reaches[baselines[k].commit] != "absent"]
    )
    return Review(
        recorded=[baselines[k] for k in sorted(baselines) if k in claimed],
        unrecovered=unrecovered,
        unreadable=unreadable,
        orphaned=[baselines[k] for k in sorted(baselines) if k not in claimed],
        conflicts=conflicts,
        inputs_missing=inputs_missing,
        inputs_unchecked=inputs_unchecked,
        untagged=[baselines[k] for k in sorted(baselines) if not named[baselines[k].commit]],
        unreachable=[
            (baselines[k], reaches[baselines[k].commit])
            for k in sorted(baselines)
            if reaches[baselines[k].commit] != "reachable"
        ],
        # Only where the commit is present: a baseline whose commit this repository has lost cannot be
        # read at all, and `unreachable` already says so. Reporting it twice, once as "absent" and
        # once as "declares nothing", would send the reader after the wrong fix.
        misnamed=[
            (baselines[k], declared)
            for k in sorted(baselines)
            if reaches[baselines[k].commit] != "absent"
            and (declared := declared_in(repo_root, baselines[k].commit, baselines[k].source))
            != baselines[k].contractType
        ],
    )


# The fields a disagreement is reported for. `normalised_path` is deliberately absent: it is DERIVED
# from `recorded_path`, so reporting it too says one thing twice - twenty-two lines for eleven
# disagreements, in the aggregators. It follows its source instead.
_MERGED = ("name", "recorded_path", "deployed_at")


def _by_address(entries: Iterable[Entry]) -> tuple[list[Entry], list[Problem]]:
    """One entry per deployed contract, and the disagreements between the manifests describing it.

    A contract is often described by two manifests: 44 of the aggregators' 85 addresses are in both
    `v3-aggregators.json` and `v3-oracles.json`, and only the first carries `deploymentTime`. Listed
    separately they became two things to recover, one of which reported "no deployment time recorded"
    while the time sat in the other row - 64 of 152 outcomes in the first run.

    It is the same rule as everywhere else here: the ADDRESS is the identity of a deployed contract, so
    two rows about one address are two descriptions of one thing, not two things.

    A field one manifest supplies and the other omits is taken. A field they give DIFFERENTLY is a
    disagreement about one immutable artefact: it is reported, and left UNSET. Keeping the first was
    letting manifest filename order decide, silently - and there is no right pick, because the older
    manifest recorded the path the file had before it moved. Recovery finds the real one at the
    baseline commit by contract name, so nothing needs the guess."""
    merged: dict[str, Entry] = {}
    # Per address, per contested field, every description of it in the order met - so ONE row can name
    # them all. Collected rather than formatted where the disagreement is found, because the row belongs
    # to the MERGED entry, and that only knows every manifest describing the address once the merge ends.
    disagreements: dict[str, dict[str, list[tuple[str, object]]]] = {}
    # The FIRST manifest to claim each field of each address, with its value, and the fields that have
    # been contested. Comparing against what is HELD is not enough once three manifests describe one
    # address: a disagreement unsets the field, so the third row meets an empty value, `ours or theirs`
    # takes it, and the reader is told about one disagreement while a third description quietly becomes
    # the answer. A claim survives being contested, so every later description is judged against it.
    claimed: dict[str, dict[str, tuple[str, object]]] = {}
    contested: dict[str, set[str]] = {}
    for entry in entries:
        entry_key = key(entry.chain_id, entry.address)
        claims = claimed.setdefault(entry_key, {})
        disputed = contested.setdefault(entry_key, set())
        held = merged.get(entry_key)
        if held is None:
            # Every entry that leaves here knows which manifests describe it, so a report never has to
            # ask again - one for most, and for the contested ones all of them, in the order met.
            merged[entry_key] = replace(entry, manifests=(entry.manifest,))
            for field in _MERGED:
                if value := getattr(entry, field):
                    claims[field] = (entry.manifest, value)
            continue
        settled: dict[str, object] = {
            "manifests": held.manifests + tuple(m for m in (entry.manifest,) if m not in held.manifests)
        }
        for field in _MERGED:
            theirs = getattr(entry, field)
            claim = claims.get(field)
            if theirs and claim is None:
                claims[field] = (entry.manifest, theirs)
            elif theirs and claim is not None and claim[1] != theirs:
                # Seeded with the CLAIM, so the row carries the description being disagreed with and not
                # only the ones that disagree.
                disagreements.setdefault(entry_key, {}).setdefault(field, [claim]).append((entry.manifest, theirs))
                disputed.add(field)
            # A field a manifest supplies and another omits is taken; one they give DIFFERENTLY is left
            # UNSET, and stays unset however many more manifests offer a value for it.
            settled[field] = None if field in disputed else (claims.get(field) or (None, None))[1]
        # Follows its source: a path nobody can settle has no normalised form either.
        settled["normalised_path"] = (
            (held.normalised_path or entry.normalised_path) if settled["recorded_path"] else None
        )
        merged[entry_key] = replace(held, **settled)
    # ONE row per contested address. A row per FIELD named the first manifest and one other, so a third
    # description of the same address was unnamed in every row it did not appear in - and four rows said
    # "one address is wrong" four times where the reader needed one row saying which files to open.
    return list(merged.values()), [
        Problem(
            merged[entry_key],
            "; ".join(
                f"{field}: " + ", ".join(f"{manifest} says {value!r}" for manifest, value in said)
                for field, said in fields_in_dispute.items()
            ),
        )
        for entry_key, fields_in_dispute in disagreements.items()
    ]
