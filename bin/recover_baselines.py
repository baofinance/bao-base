#!/usr/bin/env python3
"""Recover the source commit of every deployed contract that has no baseline, and prove it on chain.

Reports by default and writes only when told to, like `yarn update --check`: a baseline is believed by
everything downstream, so writing one is a deliberate act.

A contract is recorded ONLY when the commit's build matches the deployed code. A candidate that does
not match is reported and skipped - an unrecovered baseline is a known gap, and a wrong one is a lie.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from Crypto.Hash import keccak

from deployment_baselines import (
    Baseline,
    Review,
    UnknownSchema,
    add,
    commit_reach,
    create_missing_tags,
    drop,
    key,
    read_baselines,
    review,
    write_baselines,
)
from deployment_records import Entry, Problem
from deployment_recovery import (
    all_commits,
    artefact_for,
    build_id,
    commit_timestamp,
    compiler_in,
    creation_block,
    differences,
    matches,
    checkouts_by_repository,
    export_tree,
    install_toolchain,
    link_libraries,
    search_passes,
    source_at,
    source_blobs,
    still_to_try,
    strip_metadata,
    submodules_at,
    without_link_addresses,
)


def _keccak256(data: bytes) -> str:
    """keccak256, because that is what this ecosystem hashes with.

    sha256 was the first choice and it was convenience deciding a format other people have to verify
    against: it is in the stdlib, and keccak is not. But anyone checking a recorded digest by hand
    reaches for `cast keccak`, and a record exists to be checked."""
    digest = keccak.new(digest_bits=256)
    digest.update(data)
    return digest.hexdigest()


class _ChainRefused(Exception):
    """A `cast` command did not answer, carrying what it said.

    Raised rather than returned as an absence, because the two are different findings and only one of
    them is about the contract: a chain that cannot be reached, a key that has expired and a node
    without the history are all problems with the ASKING, while "there is no code at this address" is
    an answer. Collapsing them told the reader their contract could not be proved when in truth it
    had never been examined."""


def _cast(*arguments: str) -> str:
    """One `cast` command's output. Raises `_ChainRefused` with its own words if it did not answer."""
    done = subprocess.run(["cast", *arguments], capture_output=True, text=True)
    if done.returncode != 0:
        said = (done.stderr or done.stdout or "").strip().splitlines()
        raise _ChainRefused(f"`cast {arguments[0]}` failed: {said[0] if said else 'it said nothing'}")
    return done.stdout.strip()


def _deployed_code(address: str, chain: str) -> tuple[bytes | None, str]:
    """The runtime code at an address, and what stopped the reading if it could not be read.

    `cast` reads the endpoint from foundry.toml and the environment itself, so no key is handled here.
    Etherscan is deliberately not used: the creation transaction would need it, and this comparison
    does not - which matters because CI has an RPC and does not have an Etherscan key.

    An address with NO code answers `(None, "")`: the chain replied, and what it said is that nothing
    is deployed there. A chain that could not be asked answers `(None, <its words>)`, and the caller
    says which - the two are different findings about different things."""
    try:
        answer = _cast("code", address, "--rpc-url", chain)
    except _ChainRefused as refused:
        return None, str(refused)
    if not answer.startswith("0x"):
        return None, f"`cast code` answered {answer[:60]!r}, which is not code"
    body = answer[2:]
    return (bytes.fromhex(body) if body else None), ""


def _deployment(address: str, chain: str, claimed: str) -> tuple[tuple[int, str] | None, str]:
    """The block the contract was created in and that block's UTC timestamp, or None.

    `claimed` - the manifest's `deploymentTime` - only ESTIMATES where to look, because it is the
    deploy SCRIPT's clock: written after the broadcast, so usually just after the transaction - 2m55s
    after, for BaoPauser - and shared across a whole batch of aggregators deployed at different
    moments. Two mainnet aggregators record a time whose block holds no code at all, so the search
    runs both ways from the estimate, and the head of the chain bounds the half that runs forward.

    The second half of the answer is what stopped the search, said in the chain's own words where the
    chain is what stopped it. A search that ran and found nothing is `(None, "")`: the blocks were
    read and none of them is where this contract began."""
    try:
        at = _cast(
            "find-block",
            str(int(datetime.fromisoformat(claimed.replace("Z", "+00:00")).timestamp())),
            "--rpc-url",
            chain,
        )
        if not at.isdigit():
            return None, f"`cast find-block` answered {at[:60]!r}, which is not a block number"
        head = _cast("block-number", "--rpc-url", chain)
        if not head.isdigit():
            return None, f"`cast block-number` answered {head[:60]!r}, which is not a block number"

        def has_code(block: int) -> bool:
            return _cast("code", address, "--rpc-url", chain, "--block", str(block)) not in ("", "0x")

        block = creation_block(has_code, near=int(at), ceiling=int(head))
        if block is None:
            return None, ""
        seconds = _cast("block", str(block), "--rpc-url", chain, "--field", "timestamp")
    except _ChainRefused as refused:
        return None, str(refused)
    if not seconds.isdigit():
        return None, f"`cast block` answered {seconds[:60]!r}, which is not a timestamp"
    return (block, datetime.fromtimestamp(int(seconds), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")), ""


def _construct(creation: str, chain: str, block: int) -> tuple[bytes | None, str]:
    """The runtime code this creation bytecode produces, by running its constructor.

    `eth_call` against a creation payload returns what the constructor returns, which IS the runtime
    code - so the immutables it writes are in the answer, and the comparison no longer has to exclude
    them. No transaction, no key, nothing written.

    AT THE DEPLOY BLOCK, because a constructor can capture chain state: one of the pauser's immutables
    is a `block.timestamp`, and running now would reproduce today's rather than the deploy's. It needs
    an archive node, which is the same thing the creation-block search already needs.

    `creation` is the payload as DEPLOYED - the creation bytecode with the constructor's arguments
    appended, which is how a deployment transaction carries them. The aggregators need none
    (`constructor() Aggregator_PAXG_USD(PAXG_USD.FEED, PAXG_USD.HEARTBEAT, 1, false) {}` hard-codes
    everything), so for them the payload IS the bytecode; harbor's do
    (`Genesis_v1(address minter_)`, `StabilityPool_v1(address minter_, address liquidationToken_, …)`)
    and running those without arguments silently constructs a contract whose immutables are zero -
    which then fails the comparison as though the SOURCE were wrong. `constructor_arguments` is where
    the real ones come from.

    The second half of the answer is why there is no code, said in the chain's own words. A
    constructor that REVERTED and a node that could not be reached both leave nothing to compare, and
    only the first is about this contract - so the reason travels up rather than being flattened into
    an absence the caller has to guess at."""
    try:
        answer = _cast("call", "--rpc-url", chain, "--block", str(block), "--create", creation)
    except _ChainRefused as refused:
        return None, str(refused)
    if not answer.startswith("0x"):
        return None, f"`cast call` answered {answer[:60]!r}, which is not code"
    if len(answer) <= 2:
        return None, "the constructor returned no code"
    return bytes.fromhex(answer[2:]), ""


def _constructor_arguments(address: str, chain: str, creation: bytes) -> str | None:
    """The arguments the deployment appended to `creation`, as hex, and why there are none if so.

    The two halves are different findings: an explorer that could not be asked is a problem with the
    ASKING, while a payload that is not this build is a statement about this contract - it says the
    tail is somebody else's arguments and must not be used. Only the second should ever read as a
    reason not to trust a candidate.

    READ, not guessed: a deployment transaction carries the creation bytecode with the arguments
    ABI-encoded after it, so whatever follows our own build's bytecode in the deployed payload IS
    what was passed. Nothing needs to know the constructor's signature, and nothing is decoded.

    The prefix is CHECKED rather than assumed: if the payload does not begin with the bytecode this
    build produced, the tail is not this contract's arguments and returning it would construct
    something arbitrary. That check is also why an empty answer is a real one - a constructor that
    takes nothing leaves the payload equal to the bytecode.

    Checked with the METADATA STRIPPED, though the tail is taken by LENGTH. A rebuild's CBOR trailer
    never equals the deployed one - each hashes the sources and settings of the tree it was built in,
    which is why every other comparison here strips both sides - so a byte-exact prefix would refuse
    every contract rather than the wrong ones. The trailer's LENGTH is part of the code either way,
    so where the arguments begin is not in doubt.

    `cast creation-code` reads it from a block explorer, which is the only thing that knows which
    transaction created an address: these implementations are deployed with a plain `new`, so no
    receipt names them, and the explorer's index is what maps address to creation."""
    try:
        payload = _cast("creation-code", address, "--rpc-url", chain)
    except _ChainRefused as refused:
        return None, str(refused)
    if not payload.startswith("0x"):
        return None, f"`cast creation-code` answered {payload[:60]!r}, which is not a payload"
    deployed = bytes.fromhex(payload[2:])
    if len(deployed) < len(creation) or strip_metadata(deployed[: len(creation)]) != strip_metadata(creation):
        return None, "the deployed creation payload is not what this build produces"
    return deployed[len(creation) :].hex(), ""


def _build(tree: Path, source: str, out: Path, compiler: str) -> bool:
    """Compile this source file and its closure, exactly as the deploy would have.

    PINNED to `compiler`, which is REQUIRED, because a commit does not fix the compiler on its own: it
    fixes it only as far as the pragma and `foundry.toml` do, and the rest is whatever versions this
    machine has installed. The aggregators pin `0.8.30` exactly, bao-base's sources are mostly ranges,
    and a rebuild that picks a different version from the deploy's is asked to match bytecode it cannot
    produce. A contract whose deployed code names no compiler is refused by the caller and never
    reaches here - building it unpinned would be this function choosing a version nothing vouches for.

    ONE source per build, and the exit code is that source's answer. Compiling the group together was
    cheaper - twenty aggregators at one commit share a closure - but `forge` writes no artefact for ANY
    source when one of them does not compile, so one broken file discarded every contract waiting at
    that commit, each then reported as "no candidate built what is deployed": a search that found
    nothing, where in truth it never looked. Measured at 1.6-1.7x the time for the whole run, against a
    defect that hides contracts, and it also removes the split-on-failure path that recovering the
    group's other answers would otherwise need.

    METADATA IS LEFT ON, and that one setting decides whether anything matches at all. It was forced
    off - `FOUNDRY_CBOR_METADATA=false`, `FOUNDRY_BYTECODE_HASH=none` - because the metadata embeds
    source hashes that cannot be expected to agree. True, and the action was still wrong: the trailer
    is stripped from both sides anyway, and disabling it changes the CODE BEFORE IT. `Assembly.cpp`
    ends the code with an `INVALID` only when something follows it to separate from, and the metadata
    is that something (`!m_subs.empty() || !m_data.empty() || !m_auxiliaryData.empty()`), so a contract
    with no sub-assemblies and no data section loses the byte along with the metadata:

        ethereum/solidity, libevmasm/Assembly.cpp, in `assemble()`
        https://raw.githubusercontent.com/ethereum/solidity/develop/libevmasm/Assembly.cpp

    (`develop` moves, so the line will not stay where it is; `git grep "help tests find
    miscompilation"` finds it in any checkout.) Measured on
    `Aggregator_stETH_USD_mainnet` at a2ac04c401, one source, one compiler:

        metadata off   3302 bytes, strips to 3302, ends ...610cb956
        metadata on    3356 bytes, strips to 3303, ends ...610cb956fe
        deployed       3356 bytes, strips to 3303, ends ...610cb956fe

    So the metadata-off build was a byte shorter than anything that has ever been deployed. It is not
    alignment padding - one byte, never a computed count, and 3303 is no more word-aligned than 3302.
    `BaoPauser_v1` recovered anyway because it HAS a data section, which puts its terminator further
    back where stripping the trailer does not reach - which is how a defect survives its first
    success."""
    done = subprocess.run(
        ["forge", "build", source, "--use", compiler],
        cwd=tree,
        capture_output=True,
        text=True,
        env={**_environment(), "FOUNDRY_OUT": str(out)},
    )
    if done.returncode != 0:
        sys.stderr.write(done.stdout + done.stderr)
    return done.returncode == 0


def _environment() -> dict[str, str]:
    """The caller's environment with every FOUNDRY_* variable dropped but the install location.

    The same scrub `verify-audit` applies, for the same reason: those variables steer the build -
    optimizer, via_ir, remappings, artefact paths - so letting them through would make a recovery
    depend on the shell it was started from, and a baseline must not."""
    return {k: v for k, v in os.environ.items() if not k.startswith("FOUNDRY_") or k == "FOUNDRY_DIR"}


@dataclass
class _Wanted:
    """One contract still looking for its baseline, and everything already known about it."""

    entry: object
    onchain: bytes
    block: int
    deployed: str


def _try_commit(
    root: Path,
    commit: str,
    pending: dict[str, _Wanted],
    say: Callable[..., None],
    checkouts: dict[str, list[Path]],
) -> tuple[dict[str, tuple], set[str]]:
    """Export ONE tree at `commit`, then build each contract that is looking there on its own.

    The export is shared because making it is expensive and identical for every contract at this
    commit - the commit's files plus every submodule at its recorded gitlink, recursively. The BUILDS are not
    shared, because `forge` writes no artefact for any source in a build that fails, so grouping them
    made one source's syntax error into every waiting contract's missing baseline. `build_id` still
    keeps the work bounded by the number of distinct builds in the repository rather than by the number
    of candidates.

    Returns what matched, and which contracts were actually COMPARED here - the second being every
    contract this commit produced a build for, matching or not. It is smaller than `pending` whenever a
    source is declared nowhere at this commit, does not compile, or was built by a compiler the chain
    does not name, and the caller needs it because "compared against 5 builds" and "reached 5 commits
    and built at one of them" are different reports of a failed search."""
    # (path, name as declared THERE) - the two differ wherever the contract was renamed after its
    # deploy, and it is the declared name the build produces an artefact under.
    found_at = {
        k: source_at(root, commit, w.entry.name, w.entry.recorded_path) for k, w in pending.items() if w.entry.name
    }
    sources = {k: located for k, located in found_at.items() if located}
    if not sources:
        return {}, set()
    with tempfile.TemporaryDirectory(prefix="recover-baseline-") as scratch:
        tree = Path(scratch) / "tree"
        missing = export_tree(root, commit, tree, checkouts)
        # Said once per export rather than per build: every contract at this commit would otherwise
        # repeat it, and it only explains a build failure that has not happened yet.
        if unavailable := install_toolchain(tree):
            say(1, f"  {commit[:10]}: the pinned toolchain could not be installed: {unavailable}")
        found = {}
        compared: set[str] = set()
        for position, (entry_key, (source, declared)) in enumerate(sorted(sources.items())):
            # Its OWN output directory, so no artefact can be read as another source's: a failed
            # build writes none, and a shared directory would leave whatever was there before.
            out = Path(scratch) / f"out-{position}"
            # The deployed code says which compiler built it. Without that the rebuild takes
            # whatever this machine has installed, and a version that merely happens to be here
            # would end up recorded as the one that produced the bytecode.
            wanted = compiler_in(pending[entry_key].onchain)
            if wanted is None:
                say(0, f"  {commit[:10]}: {source} — the deployed code names no compiler, so nothing pins it")
                continue
            if not _build(tree, source, out, wanted):
                # One source's failure is one source's answer. Building the whole group at once
                # made it everybody's: `forge` writes no artefact for ANY source when one of them
                # does not compile, so a single broken file discarded every contract waiting at
                # this commit and each was reported as "no candidate built what is deployed" -
                # a search that found nothing, where in truth it never looked. Measured twice in
                # the aggregators' own history, at fa8d73f7ae and at HEAD.
                note = f"  {commit[:10]}: {source} does not compile here"
                # A build failing right after something could not be exported is almost always that,
                # and reporting only "does not build" sends the reader nowhere.
                if missing:
                    note += f", and these could not be exported: {' '.join(missing)}"
                say(0, note)
                continue
            artefact, unusable = artefact_for(out, source, declared)
            if artefact is None:
                # Reported, not skipped: the fleet has twelve contract names declared in two files
                # at once, and a silent skip makes that read as "no candidate built what is
                # deployed" - a search that found nothing rather than one that could not look.
                say(1, f"  {commit[:10]}: {source}: {unusable}")
                continue
            # solc writes into the artefact which version produced it, so the pin is CHECKED rather
            # than trusted: `--use` resolving to something else, or being ignored, would otherwise
            # leave a match that says it was built by a compiler it was not.
            built_by = (artefact.get("metadata") or {}).get("compiler", {}).get("version", "")
            if not built_by.startswith(wanted):
                say(
                    0,
                    f"  {commit[:10]}: {source} was built by {built_by or 'an unnamed compiler'}, "
                    f"not the {wanted} the deployed code names",
                )
                continue
            compared.add(entry_key)
            agreed, immutables = matches(pending[entry_key].onchain, artefact)
            if agreed:
                found[entry_key] = (commit, source, declared, artefact, immutables)
        return found, compared


def _screening(commits: list[tuple[str, str]]) -> str:
    """How a contract's screens read in a report: how many, a few of them, and WHY none proved it.

    COUNTED, not listed: a contract that screens everywhere printed hundreds of hashes on one line,
    which is the same fact repeated rather than information. The REASONS are said because they are
    different remedies - a constructor that disagreed is a source question, one that was never run
    because a library address is unknown is not - and a single sentence covering all of them told the
    reader the constructor disagreed about contracts whose constructor never ran."""
    shown = ", ".join(at[:10] for at, _ in commits[:3])
    if len(commits) > 3:
        shown += f", and {len(commits) - 3} more"
    reasons = " / ".join(dict.fromkeys(reason for _, reason in commits))
    return f"screened at {len(commits)} commit(s) ({shown}); {reasons}"


def _listing(say: Printer, title: str, rows: list[tuple[str, str, str, str]], footer: str = "") -> None:
    """One titled block with the rows behind its count, aligned, and a footer said once if there is one.

    EVERY count this run prints ends up here. A count on its own is not a report: nobody can act on "5
    cannot be read" or "11 described by two manifests that disagree" without going to find out which,
    and in a long run those numbers sit eighty lines above the end with nothing next to them."""
    if not rows:
        return
    say(0, f"\n{len(rows)} {title}:")
    widths = [max(len(row[column]) for row in rows) for column in range(3)]
    for identity, name, where, reason in sorted(rows):
        say(0, f"  {identity:<{widths[0]}}  {name:<{widths[1]}}  {where:<{widths[2]}}  {reason}")
    if footer:
        say(0, f"  {footer}")


def _problem_rows(problems: list[Problem]) -> list[tuple[str, str, str, str]]:
    """One row per problem: what identifies it, what it is called, where it is written, and what is wrong.

    Each row names EVERY manifest describing the contract, not the one the merge happened to keep - where
    two disagree, the kept one is as likely to be the innocent file. An entry `review` could not key has
    no address to be named by, since not having one is what it is, so it is identified by the path it
    records, which is what a reader greps for."""
    return [
        (
            key(problem.entry.chain_id, problem.entry.address)
            if problem.entry.chain_id and problem.entry.address
            else (problem.entry.recorded_path or problem.entry.name or "(unidentified)"),
            problem.entry.name or "(unnamed)",
            ", ".join(problem.entry.manifests or (problem.entry.manifest,)),
            problem.reason,
        )
        for problem in problems
    ]


def _listings(say: Printer, account: list[Problem], found: Review, searched: str = "") -> None:
    """Everything this run leaves unsettled: the contracts with no baseline, and what the record raises.

    An orphan IS recorded, so it does not belong among the contracts with no baseline - it is its own
    listing, as is a disagreement between manifests, which can be about an address that already has a
    baseline. `verify-audit` names both; this run counted them, and it is the same data either way.

    Called on the early exit as well, because a repository whose keyable contracts all have baselines
    returns before the search - and that is the state a finished one sits in permanently."""
    _listing(say, "not recorded", _problem_rows(account), searched)
    _listing(say, "described by two manifests that disagree", _problem_rows(found.conflicts))
    _listing(
        say,
        "recorded but no manifest claims them any more",
        [
            (
                key(baseline.chainId, baseline.address),
                baseline.contractType,
                baseline.source,
                f"recorded at {baseline.commit[:10]}, and no manifest describes this address",
            )
            for baseline in found.orphaned
        ],
    )


def _selected(wanted: str, chain_id: int | None, chain: str, address: str) -> bool:
    """Whether `--only` names this deployed contract, by either spelling. An empty selector names all.

    ONE definition for both modes. Recovery narrows the backlog and `--reprove` narrows the record -
    disjoint sets, since a contract leaves one by entering the other - but "only this contract" is the
    same idea either way, and two copies of the matching would drift apart at the first fix.

    A deployed contract is a chain AND an address: `0xA8643E35…` is `Aggregator_stETH_AAPL_arbitrum` on
    42161 and `Aggregator_hsfxUSD_ETH_USD_mainnet` on 1, so an address alone selects both. The name is
    accepted too, because it is what the progress lines print and a person copies what they see."""
    return not wanted or wanted in (key(chain_id, address), f"{chain}/{address}".lower())


def _reprove(root: Path, baselines: dict[str, Baseline], say: Callable[..., None]) -> list[tuple[str, str, str, str]]:
    """Rebuild each baseline from what it records and check it still produces the bytecode it claims.

    `creationBytecodeKeccak256` is where the chain's verdict lives on. The screen and the constructor
    proof ran once, at recovery, against the deployed code; afterwards that hash is the only thing
    carrying the result, and nothing has ever read it back. This reads it back.

    ONE export per COMMIT rather than per baseline - twelve commits carry the aggregators' eighty-three
    records - and the compiler comes from the baseline, whose version prefix is what `--use` takes.

    No chain and no search: the commit, the source, the compiler and the settings are all recorded, so
    this says whether the repository still holds a tree that builds what was deployed. It cannot say
    that a fresh search would choose the same commit; only a full re-derive does that."""
    failed: list[tuple[str, str, str, str]] = []
    # The tree's own layout, which every export reads and no export changes - so once, here.
    checkouts = checkouts_by_repository(root)
    at_commit: dict[str, list[Baseline]] = {}
    for baseline in baselines.values():
        at_commit.setdefault(baseline.commit, []).append(baseline)
    for position, (commit, wanted) in enumerate(sorted(at_commit.items()), start=1):
        say(1, f"[{position:>3}/{len(at_commit)}] {commit[:10]}  {len(wanted)} baseline(s)")
        with tempfile.TemporaryDirectory(prefix="reprove-") as scratch:
            tree = Path(scratch) / "tree"
            missing = export_tree(root, commit, tree, checkouts)
            if unavailable := install_toolchain(tree):
                say(1, f"  {commit[:10]}: the pinned toolchain could not be installed: {unavailable}")
            for index, baseline in enumerate(sorted(wanted, key=lambda b: b.address)):
                entry_key = key(baseline.chainId, baseline.address)
                row = (entry_key, baseline.contractType, baseline.source)
                out = Path(scratch) / f"out-{index}"
                # The version prefix, because that is what `--use` resolves; the record carries the
                # full `0.8.30+commit.73712a01`, which is what the artefact is then checked against.
                if not _build(tree, baseline.source, out, baseline.compiler.split("+")[0]):
                    note = f"does not rebuild at {commit[:10]}: {baseline.source} no longer compiles"
                    if missing:
                        note += f", and these could not be exported: {' '.join(missing)}"
                    failed.append((*row, note))
                    continue
                artefact, unusable = artefact_for(out, baseline.source, baseline.contractType)
                if artefact is None:
                    failed.append((*row, f"does not rebuild at {commit[:10]}: {unusable}"))
                    continue
                # The same unlinked form the baseline recorded, so this needs no chain to reproduce
                # it: a library address is not part of what the source, compiler and settings decide.
                digest = _keccak256(without_link_addresses(artefact["bytecode"]))
                if digest != baseline.creationBytecodeKeccak256:
                    built_by = (artefact.get("metadata") or {}).get("compiler", {}).get("version", "")
                    note = f"does not rebuild to {baseline.creationBytecodeKeccak256[:16]}… at {commit[:10]}"
                    if built_by and built_by != baseline.compiler:
                        # Said only here: a compiler difference is the likeliest cause, and naming it
                        # beside a passing hash would be noise.
                        note += f" (built by {built_by}, recorded {baseline.compiler})"
                    failed.append((*row, note))
    return failed


class Printer:
    """Says what a run is doing: at the level the caller chose, into the sink the caller chose.

    ONE object rather than a level and a write function, because a run needs both - the heartbeat reads
    `level` directly, since it prints only at 0, where it exists to fill the silence that hiding the
    per-commit lines creates.

    The SINK belongs to the caller because narration and the caller's own verdict belong on ONE stream.
    Split across two, captured output arrives out of order - stdout is block-buffered through a pipe and
    stderr is not - and each caller then has to flush by hand to compensate. Passing the sink in is what
    lets a command put this library's narration wherever the rest of its own output goes."""

    def __init__(self, level: int, write: Callable[[str], None] | None = None) -> None:
        self.level = level
        # Flushed: a run is long, and a reader watches it happen rather than reading it afterwards.
        self.write = write or (lambda message: print(message, flush=True))

    def __call__(self, level: int, message: str = "") -> None:
        if self.level >= level:
            self.write(message)


@dataclass
class Recovery:
    """What a run produced: the record it derived, and every contract that is not in it.

    Returned rather than printed, so a caller can ask what a regeneration would change without parsing a
    transcript to find out. The three lists are already IN `account` - which carries every contract that
    will not be in the record - but each has a remedy of its own to print, and `account` alone cannot say
    which contract needs which."""

    baselines: dict[str, Baseline]
    account: list[Problem]
    refused: list[tuple[str, Entry, str]]
    # Each screen that did not prove it, as (commit, why) - the reasons differ and so do their
    # remedies, so a caller must be able to say which rather than one sentence for all of them.
    unproven: list[tuple[str, Entry, list[tuple[str, str]]]]
    recovered: int
    built: int
    # Every commit the search ran over, newest first, as (commit, timestamp). The provenance of a
    # "nothing built it": that means nothing in ANY ref did, which is worth saying with the range.
    dated: list[tuple[str, str]]


def recover(
    root: Path,
    found: Review,
    outstanding: list[Entry],
    *,
    regenerate: bool,
    write: bool,
    say: Printer,
) -> Recovery:
    """Find the commit that built each contract in `outstanding`, and prove it against the deployed code.

    Everything that needs the chain, the git history, or a build. It narrates progress as it goes, because
    a run is minutes long and silence reads as a hang - but the closing REPORT belongs to the caller, which
    is what lets a second caller say something different about the same result.

    EVERY line goes through `say`, so the caller decides where the narration lands and how much of it
    there is. Nothing here writes to a stream of its own choosing."""
    # Every contract that will NOT be in the record when this run ends, and why - seeded with what
    # `review` could not even key, because those never become candidates and so no later stage is in a
    # position to report them. `drop` is the only way anything else joins them.
    account: list[Problem] = list(found.unreadable)
    # The tree's own layout, which every export reads and no export changes - so once, here, rather
    # than rebuilt for each of the hundreds of commits a search walks.
    checkouts = checkouts_by_repository(root)
    # Regeneration accumulates into an EMPTY record: what it derives is the answer, and reading the old
    # one to add to it would make the output depend on what was there.
    baselines = {} if regenerate else read_baselines(root)

    # Every contract's chain facts first, because they decide its candidate window and cost only RPC.
    say(0, f"\nreading the chain for {len(outstanding)} contract(s)")
    pending: dict[str, _Wanted] = {}
    for position, entry in enumerate(outstanding, start=1):
        entry_key = key(entry.chain_id, entry.address) if entry.chain_id else f"{entry.chain}/{entry.address}"
        say(0, f"[{position:>3}/{len(outstanding)}] {entry.chain}/{entry.address}  {entry.name}")
        if not entry.name:
            say(0, "  the manifest names no contract, so nothing can be located or built")
            drop(pending, account, entry_key, entry, "the manifest names no contract")
            continue
        if not entry.deployed_at:
            say(0, "  no deployment time recorded, so the window cannot be placed")
            drop(pending, account, entry_key, entry, "no deployment time recorded")
            continue
        onchain, refused = _deployed_code(entry.address, entry.chain)
        if onchain is None:
            # The chain's own words where the chain is what stopped it, so a broken endpoint does not
            # read as a finding about the contract.
            why = refused or f"nothing is deployed at that address on {entry.chain}"
            say(0, f"  no deployed code to compare against: {why}")
            drop(pending, account, entry_key, entry, f"no deployed code to compare against: {why}")
            continue
        deployment, refused = _deployment(entry.address, entry.chain, entry.deployed_at)
        if deployment is None:
            why = refused or f"no block on {entry.chain} is where it was created"
            say(0, f"  could not place the deploy: {why}")
            drop(pending, account, entry_key, entry, f"could not place the deploy: {why}")
            continue
        block, deployed = deployment
        # The CHAIN's timestamp, not the manifest's: the manifest records the deploy script's clock,
        # which is written after the broadcast and so always sits late. It decides which commits count
        # as before the deploy and which as after, which is the whole two-pass split.
        say(1, f"          created in block {block} at {deployed}, {len(onchain)} bytes on chain")
        pending[key(entry.chain_id, entry.address)] = _Wanted(entry, onchain, block, deployed)

    # THE DEPLOY BLOCK DECIDES WHICH COMMIT, not the order things happen to be tried in. Many commits
    # compile identically, so "the first that matches" is arbitrary; "the LATEST at or before the
    # moment the contract was created" is the tree that was actually checked out, and is unique.
    #
    # So: newest first, accepting only commits at or before each contract's deploy. Whatever is still
    # unmatched then had no committed source at deploy time - a dirty tree - and takes the EARLIEST
    # commit after it, which is where that source first landed.
    dated = all_commits(root)
    passes = search_passes(dated)
    say(0, f"\ntrying every one of this repository's {len(dated)} commits for {len(pending)} contract(s)")
    recovered = 0
    built = 0
    opened = beat = time.monotonic()
    # Proved, but not recordable — or recordable here and not yet anywhere else. Each carries the
    # manifest that names the contract, because a fleet has many and "this address is broken" otherwise
    # sends the reader to grep for it.
    refused: list[tuple[str, Entry, str]] = []
    # Every commit each contract screened at without being proved. A screen masks the immutables, so
    # matching it is a candidacy and not an answer - which is why these do not end the search, and why
    # they are only an OUTCOME for a contract that was never proved anywhere.
    screened: dict[str, list[tuple[str, str]]] = {}
    # Which contracts each build (keyed by `build_id`) has already been TRIED for, and which commit
    # first carried that build - so a skip can say what it duplicates rather than leaving a gap in the
    # numbering that reads like a contract being dropped.
    tried: dict[str, set[str]] = {}
    claimed_by: dict[str, str] = {}
    # And which it was actually compared against, which is the smaller thing: a build is claimed above
    # before its sources are located, so a commit declaring the contract nowhere claims a build that
    # never ran. Counting the claims made every unrecovered contract read as having been compared
    # against every commit the run had reached.
    compared: dict[str, set[str]] = {}
    for label, order, admits in passes:
        if not pending:
            break
        say(1, f"\npass: commits {label} — {len(pending)} contract(s) still looking")
        for position, (commit, when) in enumerate(order, start=1):
            if not pending:
                break
            looking = {k: w for k, w in pending.items() if admits(when, w.deployed)}
            if not looking:
                continue
            place = f"[{position:>3}/{len(order)}] {commit[:10]} {when}"
            identity = build_id(root, commit)
            fresh = still_to_try(tried, identity, looking)
            if not fresh:
                say(1, f"{place}  same build inputs as {claimed_by[identity][:10]}, already tried — skipped")
                continue
            claimed_by.setdefault(identity, commit)
            waiting = f"{len(fresh)} waiting"
            if len(fresh) != len(looking):
                waiting += f" ({len(looking) - len(fresh)} already tried against these inputs)"
            say(1, f"{place}  {waiting}, building…")
            started = time.monotonic()
            outcome, compared_here = _try_commit(root, commit, {k: looking[k] for k in fresh}, say, checkouts)
            compared.setdefault(identity, set()).update(compared_here)
            built += 1
            # At the default level the per-commit lines are hidden, so a long stretch of builds that
            # match nothing would print nothing at all - which is the silence C3 hid behind. A line
            # every half minute keeps the run legible without becoming the flood `-v` is for.
            if say.level == 0 and time.monotonic() - beat > 30:
                beat = time.monotonic()
                elapsed = int(time.monotonic() - opened)
                say(
                    0,
                    f"  … {built} builds, {recovered} recorded, {len(pending)} still looking,"
                    f" {elapsed // 60}m{elapsed % 60:02d}s elapsed",
                )
            say(1, f"{' ' * len(place)}  {time.monotonic() - started:.1f}s, {len(outcome)} matched")
            for entry_key, (built_at, source, declared, artefact, immutables) in outcome.items():
                # NOT popped here. What follows can still refuse this commit, and a contract taken out
                # of the search on a SCREEN is one no later commit is ever tried for.
                wants = pending[entry_key]
                entry = wants.entry
                # A build that links a library cannot be CONSTRUCTED as it stands, so its addresses
                # are read from the deployed runtime code first. The HASH is taken from the unlinked
                # form, which is what the source, compiler and settings determine - the addresses are
                # recorded separately, as the deployment inputs they are, exactly as the creation
                # bytecode already excludes constructor arguments.
                linked, libraries = link_libraries(artefact, wants.onchain)
                creation = without_link_addresses(artefact["bytecode"])
                made = commit_timestamp(root, built_at)
                say(0, f"    MATCHES {entry.chain}/{entry.address}  {entry.name}")
                say(0, f"      built from {source} at {built_at[:10]}, committed {made or 'unknown'}")
                if declared != entry.name:
                    # Said out loud because it changes what the baseline means: the manifest's name is
                    # today's, and this is what the contract was called when it was deployed.
                    say(2, f"      NOTE: declared {declared} there — renamed to {entry.name} since")
                # The screen above ignored the immutables. Run the constructor and compare what it
                # actually produces, so they are IN the verdict rather than excluded from it.
                immutable_regions = artefact["deployedBytecode"].get("immutableReferences") or {}
                if linked is None:
                    say(0, "      NOT PROVED HERE: it links a library that the deployed code never names,")
                    say(0, "      so nothing here says what address it had — still looking at the other commits")
                    screened.setdefault(entry_key, []).append(
                        (built_at, "the constructor was never run: a library address is unknown")
                    )
                    continue
                # The deployed payload is the bytecode plus whatever the constructor was given, and
                # only the chain knows the second part. Without it a constructor taking arguments
                # runs against zeros and the contract it builds is not the one deployed.
                arguments, refused = _constructor_arguments(entry.address, entry.chain, bytes.fromhex(linked[2:]))
                if arguments is None:
                    say(0, f"      NOT PROVED HERE: {refused}")
                    say(0, "      so the constructor's arguments are unknown — still looking at the other commits")
                    screened.setdefault(entry_key, []).append((built_at, refused))
                    continue
                produced, refused = _construct(linked + arguments, entry.chain, wants.block)
                if produced is None:
                    say(0, f"      NOT PROVED HERE: at block {wants.block}, {refused}")
                    say(0, "      so the immutables cannot be checked — still looking at the other commits")
                    screened.setdefault(entry_key, []).append((built_at, refused))
                    continue
                explained, unexplained = differences(
                    strip_metadata(wants.onchain), strip_metadata(produced), immutable_regions, entry.address
                )
                if unexplained:
                    say(0, "      NOT PROVED HERE: the constructor does not reproduce what is deployed —")
                    for line in unexplained:
                        say(0, f"        {line}")
                    say(0, "      the code outside the immutables matches — still looking at the other commits")
                    # The tree that differs only in a value that becomes an immutable screens exactly
                    # like the tree that was deployed, so the search has to go on. Both mainnet BTC
                    # aggregators screened at the commit before their deploy, where the staleness
                    # constant was an hour, against a chain holding a day - written by the commit two
                    # minutes AFTER they were created, which the second pass reaches.
                    screened.setdefault(entry_key, []).append(
                        (built_at, "the constructor ran but did not reproduce what is deployed")
                    )
                    continue
                # Proved. Nothing later can be a better answer, so the search for it ends here.
                del pending[entry_key]
                say(2, f"      constructor reproduces the deployed code; {len(immutables)} immutables:")
                for value in immutables:
                    say(2, f"        {value}")
                for line in explained:
                    say(2, f"      {line} — differs by construction, as expected")
                if made and made > wants.deployed:
                    say(0, f"      NOTE: committed AFTER the {wants.deployed} deploy — it ran from an uncommitted tree")
                # A baseline is only as good as the commit it names, and a commit no ref reaches will
                # never go anywhere - `git push` pushes refs. Refused here rather than left to the
                # check, because `git stash drop` can destroy it before any check runs.
                reach = commit_reach(root, built_at)
                if reach == "none":
                    say(0, f"      REFUSED: {built_at[:10]} is on no branch or tag, so nothing preserves it.")
                    say(0, "      It is the only source for this deployment — put it on a branch and push it:")
                    say(0, f"        git branch deployed/{entry.name} {built_at}")
                    say(0, f"        git push origin deployed/{entry.name}")
                    refused.append((entry_key, entry, built_at))
                    continue
                # What the commit alone does not settle, taken from the build that just proved it.
                # solc writes its own metadata into the artefact, so the compiler and the settings are
                # the ones that produced this bytecode rather than a second reading of foundry.toml,
                # and `sources` there is the closure it actually read.
                metadata = artefact["metadata"]
                placed = submodules_at(root, built_at, checkouts)
                baselines = add(
                    baselines,
                    Baseline(
                        chainId=entry.chain_id,
                        chain=entry.chain,
                        address=entry.address,
                        contractType=entry.name,
                        source=source,
                        # EVERY manifest describing it, in the order met - the merge already gathered
                        # them so a conflict row could name them all, and this is the same fact kept.
                        stateFiles=list(entry.manifests or (entry.manifest,)),
                        commit=built_at,
                        commitTimestamp=made or "",
                        deployBlock=wants.block,
                        deployTimestamp=wants.deployed,
                        creationBytecodeKeccak256=_keccak256(creation),
                        compiler=metadata["compiler"]["version"],
                        # `compilationTarget` is `source` and `contractType` said again.
                        settings={
                            name: value for name, value in metadata["settings"].items() if name != "compilationTarget"
                        },
                        # One walk, shared: naming the sources needs to know WHERE each submodule
                        # can be read, and the record needs the commits it names - the same answer.
                        sources=source_blobs(root, built_at, metadata["sources"], placed),
                        submodules={path: at for path, (at, _) in placed.items()},
                        libraries=libraries,
                        constructorArguments=arguments,
                    ),
                )
                recovered += 1
                # Saved as each is proved rather than at the end: these runs are long enough to be
                # interrupted, and each baseline is an independent fact with nothing spanning them.
                if write:
                    write_baselines(root, baselines)

    # Read from what is STILL being looked for, not from every screen that happened: a contract proved
    # at a later commit passed through the screen that failed on its way there, and listing it as an
    # outcome would report a recovered contract as a failure.
    unproven = [
        (entry_key, wants.entry, screened[entry_key]) for entry_key, wants in pending.items() if entry_key in screened
    ]
    # Everything that was NOT recorded, gathered by the same call that takes it out of the run, so a
    # contract cannot leave without a row. The blocks above carry the remedies - push the branch, look
    # at the immutable - and this carries the completeness.
    for entry_key, entry, proved_at in refused:
        drop(pending, account, entry_key, entry, f"proved at {proved_at[:10]}, but that commit is on no branch")
    for entry_key, entry, commits in unproven:
        drop(
            pending,
            account,
            entry_key,
            entry,
            _screening(commits),
        )
    # Whatever is left was searched for and not found. "Nothing built it" would be untrue of a contract
    # something built everywhere except an immutable, and those have just been taken out above with the
    # commits that came close. Snapshotted because `drop` removes as it records.
    for entry_key, wants in list(pending.items()):
        drop(
            pending,
            account,
            entry_key,
            wants.entry,
            # Both numbers, because their GAP is the diagnosis: compared against all of them says the
            # source is not in this repository, and compared against few of them says most candidates
            # never produced a build to compare - a broken source, or a name declared nowhere there.
            f"no candidate built what is deployed (deployed {wants.deployed}, compared against "
            f"{sum(1 for seen in compared.values() if entry_key in seen)} of "
            f"{sum(1 for seen in tried.values() if entry_key in seen)} distinct build(s))",
        )
    return Recovery(
        baselines=baselines,
        account=account,
        refused=refused,
        unproven=unproven,
        recovered=recovered,
        built=built,
        dated=dated,
    )


@dataclass
class Regeneration:
    """How a freshly derived record differs from the one committed.

    `unreadable` is empty when the committed record parsed; when it is not there is nothing to compare
    against, so `changes` is empty. A record that cannot be read is the case regeneration exists to
    repair, which makes it an ANSWER here - it would be replaced entirely - rather than an exception
    every caller has to know to catch."""

    unreadable: str
    changes: list[tuple[str, Baseline | None, Baseline | None]]


def regeneration_changes(root: Path, baselines: dict[str, Baseline]) -> Regeneration:
    """Compare a derived record against the committed one, and return the differences as data.

    NOTHING CALLS THIS TODAY. It was written while two commands asked the question and worded the answer
    differently; the surface then collapsed to one command whose check is COVERAGE - does every deployed
    contract have a baseline - rather than a re-derive, and the caller went with it.

    Kept, with its tests, because it is the only thing that can answer "would deriving the record afresh
    produce the one that is committed". That is the strongest statement available about a record being
    correct rather than merely current, and a re-derive mode would need it again."""
    try:
        committed = read_baselines(root)
    except (KeyError, UnknownSchema) as refused:
        return Regeneration(unreadable=str(refused), changes=[])
    return Regeneration(
        unreadable="",
        changes=[
            (entry_key, committed.get(entry_key), baselines.get(entry_key))
            for entry_key in sorted(set(committed) | set(baselines))
            if committed.get(entry_key) != baselines.get(entry_key)
        ],
    )


def _write_tags(root: Path, baselines: Iterable[Baseline], say: Printer) -> list[tuple[str, str]]:
    """Create the tags the record wants, locally, and say that pushing them is a step of its own.

    Called from BOTH of `--write`'s endings, which is the whole reason it is a function. A repository
    whose contracts are ALL recorded already has nothing to recover and every reason to need this - the
    check fails on an untagged commit, so a `--write` that returned before reaching here left standing
    the exact failure it had just been told to repair.

    Returns what could NOT be created, which the caller turns into a failing exit status: a repair that
    half worked and said it was fine is worse than one that refused, because the next thing the user
    does is push a record whose commits nothing preserves."""
    created, failed = create_missing_tags(root, baselines)
    if created:
        say(0, f"\ncreated {len(created)} tag(s), locally:")
        for tag in created:
            say(0, f"  {tag}")
    if failed:
        say(0, f"\n{len(failed)} tag(s) could not be created:")
        for tag, reason in failed:
            say(0, f"  {tag}: {reason}")
        say(0, "  Those commits are not preserved, so the check still fails on them.")
    say(0, "\nPush the TAGS as well as the files — `git push --tags` — or a fresh checkout resolves")
    say(0, "neither, and the check reads the checkout rather than the machine that wrote it.")
    return failed


def run(
    root: Path,
    *,
    say: Printer,
    only: str = "",
    write: bool = False,
    regenerate: bool = False,
    reprove: bool = False,
) -> int:
    """Everything the command does apart from parsing its arguments. The exit status is the answer.

    Values and a sink, not an argument list: a second caller reaches this by saying what it wants, and
    never by assembling flags for somebody else's parser and reading a transcript back."""
    found = review(root, ignoring_the_record=regenerate)
    # A deployed contract is a chain AND an address: `0xA8643E35…` is `Aggregator_stETH_AAPL_arbitrum`
    # on 42161 and `Aggregator_hsfxUSD_ETH_USD_mainnet` on 1, and an address alone selected both. The
    # id is the identity, and the name is accepted too because it is what the progress lines print and
    # a person copies what they see.
    wanted = only.lower()
    outstanding = [
        entry for entry in found.unrecovered if _selected(wanted, entry.chain_id, entry.chain, entry.address)
    ]

    # Named once because both the head-line below and the closing reconciliation read them.
    already, searching = len(found.recorded), len(found.unrecovered)
    described = already + searching + len(found.unreadable)

    # Said out loud because this run is long, occasional, and otherwise silent for minutes at a time -
    # and because every number here is one a reader would otherwise have to infer from what is missing.
    say(0, f"{root}")
    say(
        0,
        f"  manifests describe {described} deployed contracts: "
        f"{already} already recorded, {len(found.unrecovered)} without a baseline"
        # INSIDE the total rather than beside it. An entry that cannot be keyed used to sit outside the
        # arithmetic entirely, so five of the aggregators' eighty-eight could not be reconciled against
        # anything, and stayed invisible for it.
        + (f", {len(found.unreadable)} that cannot be identified" if found.unreadable else ""),
    )
    if reprove:
        # Over the RECORD, not the backlog: `--only` filters what has no baseline yet, so it can never
        # name a contract that has one - which is exactly what needs re-proving.
        recorded = {
            entry_key: baseline
            for entry_key, baseline in read_baselines(root).items()
            if _selected(wanted, baseline.chainId, baseline.chain, baseline.address)
        }
        if not recorded:
            # The message names the set it looked in. "No contract without a baseline" would be true of
            # every recorded contract, which is exactly the set this mode is about.
            if only:
                say(0, f"no recorded baseline is {only!r}; the form is 42161/0x… or arbitrum/0x…")
                return 1
            say(0, "nothing recorded to re-prove")
            return 0
        say(0, f"\nrebuilding {len(recorded)} recorded baseline(s) from what each one records")
        failed = _reprove(root, recorded, say)
        _listing(say, "not reproduced by a rebuild", failed)
        if failed:
            say(0, "  The inputs still resolve, and what they build is not what was deployed.")
            return 1
        say(0, f"\n{len(recorded)} rebuilt and matched the creation bytecode each one records")
        return 0

    if only:
        say(0, f"  --only {only}: {len(outstanding)} of them")
    if not outstanding:
        if only:
            # Distinguished from "nothing to recover", because a selector that names nothing is a
            # mistyped argument and reads exactly like a finished job otherwise.
            say(0, f"no contract without a baseline is {only!r}; the form is 42161/0x… or arbitrum/0x…")
            # Said even here. A selector narrows what is SEARCHED for, never what is reported: the
            # head-line counts the entries that cannot be identified either way, and returning before
            # this made a focused run say less about the repository than a plain one.
            _listings(say, list(found.unreadable), found)
            return 1
        say(0, "nothing to recover")
        # Nothing to RECORD is not nothing to do: the tags are the other half of the repair, and this
        # is the ending a converted repository reaches every time.
        unmade = _write_tags(root, found.untagged, say) if write else []
        _listings(say, list(found.unreadable), found)
        return 1 if unmade else 0

    done = recover(
        root,
        found,
        outstanding,
        regenerate=regenerate,
        write=write,
        say=say,
    )
    # Named locally because everything below is the report ON this one result, and `done.` in the middle
    # of a dozen f-strings buys no clarity where nothing else is in scope.
    account, refused, unproven = done.account, done.refused, done.unproven
    baselines, recovered, built, dated = done.baselines, done.recovered, done.built, done.dated

    if refused:
        say(0, f"\n{len(refused)} proved but NOT recorded — the commit is on no branch, so no remote can have it:")
        for entry_key, entry, proved_at in refused:
            say(0, f"  {entry_key}  {entry.name}  at {proved_at[:10]}")
        say(0, "  Put each on a branch and push it, then run again. Until then these are unrecoverable:")
        say(0, "  a stash entry is destroyed by `git stash drop`, and nothing else built this bytecode.")

    if unproven:
        say(0, f"\n{len(unproven)} screened but NOT recorded:")
        for entry_key, entry, commits in unproven:
            say(0, f"  {entry_key}  {entry.name}  {_screening(commits)}")
        say(0, "  A screen says the source is close: the code matches outside what the source does not")
        say(0, "  decide. What stopped each of them is on its own row — they do not share a remedy.")

    # What was searched, said once rather than per row: `all_commits` is `git log --all`, so an unmerged
    # branch and a stash are both in it, and "nothing built it" means nothing in ANY of them did - which
    # is a different statement from "nothing on this branch did".
    _listings(say, account, found, f"searched {len(dated)} commit(s) from every ref, {dated[-1][1]} to {dated[0][1]}")

    say(0, f"\n{recovered} of {len(outstanding)} recovered, from {built} build(s) over {len(dated)} candidate commits")
    # described = already recorded + recovered here + accounted for + never selected, and nothing is
    # still being looked for by now. Said as arithmetic so a removal that skipped the account can only
    # show up as a mismatch, instead of as a contract nobody mentions - which is how a screen took two
    # of them out silently.
    settled = already + recovered + len(account) + (searching - len(outstanding))
    if settled != described:
        say(0, f"  ACCOUNTING ERROR: {described} described but {settled} accounted for;")
        say(0, f"  {abs(described - settled)} contract(s) left this run without a row above.")
    if regenerate and not write:
        # The check half: what regeneration produces, against what is committed, writing nothing. It
        # proves CORRECTNESS where the currency checks prove freshness - a hand-edited record that is
        # internally consistent passes everything else in the system, and this is what catches it.
        difference = regeneration_changes(root, baselines)
        if difference.unreadable:
            # Not a crash: an unreadable record is the case regeneration exists to repair, and saying so
            # is the answer to "would regeneration change this" - it would replace it entirely.
            say(0, f"\nthe committed record cannot be read ({difference.unreadable}), so regeneration would replace it")
            return 1
        changes = difference.changes
        if changes:
            say(0, f"\n{len(changes)} baseline(s) regeneration would change:")
            for entry_key, was, now in changes:
                if was is None:
                    say(0, f"  {entry_key}  {now.contractType}  would be ADDED, at {now.commit[:10]}")
                elif now is None:
                    # The hazard E16 measured: a from-scratch run took a record from 85 to 80, and six
                    # of those were contracts it could no longer recover rather than entries it fixed.
                    say(0, f"  {entry_key}  {was.contractType}  would be REMOVED, recorded at {was.commit[:10]}")
                else:
                    say(
                        0,
                        f"  {entry_key}  {now.contractType}  recorded at {was.commit[:10]}, regenerates at {now.commit[:10]}",
                    )
            return 1
        say(0, f"\nthe record is exactly what regeneration produces: {len(baselines)} baseline(s)")
        return 0

    # Over the WHOLE record, not just what this run proved: a repository converting to the record
    # arrives with every one of its commits untagged, and none of those is something this run recovered.
    unmade = _write_tags(root, baselines.values(), say) if write else []

    if recovered and write:
        say(0, f"deployed.json holds {len(baselines)} baseline(s)")
    elif recovered:
        say(0, "not written; pass --write to record them")
    return 1 if unmade else 0
