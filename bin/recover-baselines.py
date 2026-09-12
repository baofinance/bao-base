#!/usr/bin/env python3
"""Recover the source commit of every deployed contract that has no baseline, and prove it on chain.

Reports by default and writes only when told to, like `yarn update --check`: a baseline is believed by
everything downstream, so writing one is a deliberate act.

A contract is recorded ONLY when the commit's build matches the deployed code. A candidate that does
not match is reported and skipped - an unrecovered baseline is a known gap, and a wrong one is a lie.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from Crypto.Hash import keccak

from deployment_baselines import Baseline, add, commit_reach, key, read_baselines, review, write_baselines
from deployment_recovery import (
    all_commits,
    artefact_for,
    build_id,
    commit_timestamp,
    creation_block,
    differences,
    matches,
    place_worktree,
    remove_worktree,
    search_passes,
    source_at,
    source_blobs,
    still_to_compare,
    strip_metadata,
    submodule_commits,
)


def _keccak256(data: bytes) -> str:
    """keccak256, because that is what this ecosystem hashes with.

    sha256 was the first choice and it was convenience deciding a format other people have to verify
    against: it is in the stdlib, and keccak is not. But anyone checking a recorded digest by hand
    reaches for `cast keccak`, and a record exists to be checked."""
    digest = keccak.new(digest_bits=256)
    digest.update(data)
    return digest.hexdigest()


def _deployed_code(address: str, chain: str) -> bytes | None:
    """The runtime code at an address, over the RPC the repo already configures for its fork tests.

    `cast` reads the endpoint from foundry.toml and the environment itself, so no key is handled here.
    Etherscan is deliberately not used: the creation transaction would need it, and this comparison
    does not - which matters because CI has an RPC and does not have an Etherscan key."""
    done = subprocess.run(["cast", "code", address, "--rpc-url", chain], capture_output=True, text=True)
    if done.returncode != 0 or not done.stdout.strip().startswith("0x"):
        return None
    body = done.stdout.strip()[2:]
    return bytes.fromhex(body) if body else None


def _cast(*arguments: str) -> str | None:
    done = subprocess.run(["cast", *arguments], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def _deployment(address: str, chain: str, claimed: str) -> tuple[int, str] | None:
    """The block the contract was created in and that block's UTC timestamp, or None.

    `claimed` - the manifest's `deploymentTime` - is only used to get an upper bound, because it is
    the deploy SCRIPT's clock written after the broadcast and so always sits after the transaction:
    2m55s after, for BaoPauser, and shared across a whole batch of aggregators deployed at different
    moments. `cast find-block` turns it into a block just past the answer, and the search walks back
    from there in a handful of calls."""
    at = _cast(
        "find-block", str(int(datetime.fromisoformat(claimed.replace("Z", "+00:00")).timestamp())), "--rpc-url", chain
    )
    if at is None or not at.isdigit():
        return None

    def has_code(block: int) -> bool:
        code = _cast("code", address, "--rpc-url", chain, "--block", str(block))
        return bool(code) and code != "0x"

    block = creation_block(has_code, upper=int(at))
    if block is None:
        return None
    seconds = _cast("block", str(block), "--rpc-url", chain, "--field", "timestamp")
    if seconds is None or not seconds.isdigit():
        return None
    return block, datetime.fromtimestamp(int(seconds), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _construct(creation: str, chain: str, block: int) -> bytes | None:
    """The runtime code this creation bytecode produces, by running its constructor. None if it cannot.

    `eth_call` against a creation payload returns what the constructor returns, which IS the runtime
    code - so the immutables it writes are in the answer, and the comparison no longer has to exclude
    them. No transaction, no key, nothing written.

    AT THE DEPLOY BLOCK, because a constructor can capture chain state: one of the pauser's immutables
    is a `block.timestamp`, and running now would reproduce today's rather than the deploy's. It needs
    an archive node, which is the same thing the creation-block search already needs.

    No arguments are passed, and none are needed by anything recovered so far -
    `constructor() Aggregator_PAXG_USD(PAXG_USD.FEED, PAXG_USD.HEARTBEAT, 1, false) {}` hard-codes
    everything. A constructor that DOES take arguments cannot be run without them: it fails here, and a
    failure to construct means the baseline is not written, because a comparison that cannot see the
    immutables is the weaker check this replaced."""
    done = subprocess.run(
        ["cast", "call", "--rpc-url", chain, "--block", str(block), "--create", creation],
        capture_output=True,
        text=True,
    )
    answer = done.stdout.strip()
    if done.returncode != 0 or not answer.startswith("0x") or len(answer) <= 2:
        return None
    return bytes.fromhex(answer[2:])


def _build(worktree: Path, sources: list[str], out: Path) -> bool:
    """Compile these source files and their closure, exactly as the deploy would have.

    Several at once because they share the closure: twenty aggregators at one commit compile their
    common base and libraries once between them rather than twenty times.

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
        ["forge", "build", *sources],
        cwd=worktree,
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


def _try_commit(root: Path, commit: str, pending: dict[str, _Wanted], say: Callable[..., None]) -> dict[str, tuple]:
    """Build ONE worktree at `commit` and compare every contract that is looking there.

    This is the whole point of grouping. Twenty arbitrum aggregators share a deploy and therefore share
    candidates; building the closure once per (contract, commit) made 44 candidates into 880 builds,
    where one build per commit makes it 44. Nothing about the answer changes - only how many times the
    same compilation is repeated."""
    # (path, name as declared THERE) - the two differ wherever the contract was renamed after its
    # deploy, and it is the declared name the build produces an artefact under.
    found_at = {
        k: source_at(root, commit, w.entry.name, w.entry.recorded_path) for k, w in pending.items() if w.entry.name
    }
    sources = {k: located for k, located in found_at.items() if located}
    if not sources:
        return {}
    with tempfile.TemporaryDirectory(prefix="recover-baseline-") as scratch:
        worktree, out = Path(scratch) / "wt", Path(scratch) / "out"
        missing = place_worktree(root, commit, worktree)
        try:
            if not _build(worktree, sorted({path for path, _ in sources.values()}), out):
                # Named here because a build failing right after something could not be placed is
                # almost always that, and reporting only "does not build" sends the reader nowhere.
                if missing:
                    say(0, f"  {commit[:10]}: build failed, and these were not placed: {' '.join(missing)}")
                return {}
            found = {}
            for entry_key, (source, declared) in sources.items():
                artefact = artefact_for(out, source, declared)
                if artefact is None:
                    # Reported, not skipped: the fleet has twelve contract names declared in two files
                    # at once, and a silent skip makes that read as "no candidate built what is
                    # deployed" - a search that found nothing rather than one that could not look.
                    say(1, f"  {commit[:10]}: {source} built no single artefact declaring {declared}")
                    continue
                agreed, immutables = matches(pending[entry_key].onchain, artefact)
                if agreed:
                    found[entry_key] = (commit, source, declared, artefact, immutables)
            return found
        finally:
            remove_worktree(root, worktree)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="record the baselines that verify (default: report)")
    parser.add_argument(
        "--only",
        metavar="CHAIN/ADDRESS",
        help="recover just this contract, as 42161/0x… or arbitrum/0x… — an address alone names a "
        "contract on every chain that has one at it, which is not one contract",
    )
    # Not derived from how many contracts are being recovered, which was the first design and was
    # clever in the wrong direction: it would make a bulk run impossible to make loud, which is exactly
    # when you want it loud. This is not a knob in the sense the search bound was - that one encoded a
    # judgement, and getting it wrong lost answers silently. This one only chooses how much is printed.
    #
    # USE `--verbose`. `bin/run/logging` strips `-v`/`-vv` from the argument list wherever they appear
    # and turns them into `BAO_BASE_VERBOSITY`, so the short form never reaches this parser while that
    # wrapper is in front of it. The short form is declared anyway, for when it is not.
    parser.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="--verbose adds every commit tried, twice adds the immutables and the construction detail",
    )
    arguments = parser.parse_args()

    def say(level: int, message: str = "", flush: bool = False) -> None:
        """Print when the caller asked for at least this much. A closure rather than a module global,
        so nothing carries the setting between calls invisibly."""
        if arguments.verbose >= level:
            print(message, flush=flush)

    root = Path.cwd()
    found = review(root)
    # A deployed contract is a chain AND an address: `0xA8643E35…` is `Aggregator_stETH_AAPL_arbitrum`
    # on 42161 and `Aggregator_hsfxUSD_ETH_USD_mainnet` on 1, and an address alone selected both. The
    # id is the identity, and the name is accepted too because it is what the progress lines print and
    # a person copies what they see.
    wanted = (arguments.only or "").lower()
    outstanding = [
        entry
        for entry in found.unrecovered
        if not wanted or wanted in (key(entry.chain_id, entry.address), f"{entry.chain}/{entry.address}".lower())
    ]

    # Said out loud because this run is long, occasional, and otherwise silent for minutes at a time -
    # and because every number here is one a reader would otherwise have to infer from what is missing.
    print(f"{root}")
    print(
        f"  manifests describe {len(found.recorded) + len(found.unrecovered)} deployed contracts: "
        f"{len(found.recorded)} already recorded, {len(found.unrecovered)} without a baseline"
    )
    for label, items in (
        ("cannot be read, so cannot be recovered", found.unreadable),
        ("recorded but no manifest claims them any more", found.orphaned),
        ("described by two manifests that disagree", found.conflicts),
    ):
        if items:
            print(f"  {len(items)} {label}")
    if arguments.only:
        print(f"  --only {arguments.only}: {len(outstanding)} of them")
    if not outstanding:
        if arguments.only:
            # Distinguished from "nothing to recover", because a selector that names nothing is a
            # mistyped argument and reads exactly like a finished job otherwise.
            print(f"no contract without a baseline is {arguments.only!r}; the form is 42161/0x… or arbitrum/0x…")
            return 1
        print("nothing to recover")
        return 0

    baselines = read_baselines(root)

    # Every contract's chain facts first, because they decide its candidate window and cost only RPC.
    print(f"\nreading the chain for {len(outstanding)} contract(s)")
    pending: dict[str, _Wanted] = {}
    # Every contract that leaves this loop without being searched for, and why. Each reason is printed
    # where it happens AND kept, because in a real run that line sits eighty lines above the end,
    # interleaved with the progress listing: the aggregators' run dropped six contracts here and the
    # closing tally showed them only as the gap between 83 and 76.
    dropped: list[tuple[str, str, str, str]] = []
    for position, entry in enumerate(outstanding, start=1):
        entry_key = key(entry.chain_id, entry.address) if entry.chain_id else f"{entry.chain}/{entry.address}"
        print(f"[{position:>3}/{len(outstanding)}] {entry.chain}/{entry.address}  {entry.name}")
        if not entry.name:
            print("  the manifest names no contract, so nothing can be located or built")
            dropped.append((entry_key, entry.name or "", entry.manifest, "the manifest names no contract"))
            continue
        if not entry.deployed_at:
            print("  no deployment time recorded, so the window cannot be placed")
            dropped.append((entry_key, entry.name, entry.manifest, "no deployment time recorded"))
            continue
        onchain = _deployed_code(entry.address, entry.chain)
        if onchain is None:
            print(f"  could not read the deployed code over the {entry.chain} RPC")
            dropped.append(
                (entry_key, entry.name, entry.manifest, f"deployed code unreadable over the {entry.chain} RPC")
            )
            continue
        deployment = _deployment(entry.address, entry.chain, entry.deployed_at)
        if deployment is None:
            print(f"  could not find the block it was created in over the {entry.chain} RPC")
            dropped.append(
                (entry_key, entry.name, entry.manifest, f"creation block not found over the {entry.chain} RPC")
            )
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
    print(f"\ntrying every one of this repository's {len(dated)} commits for {len(pending)} contract(s)")
    recovered = 0
    built = 0
    opened = beat = time.monotonic()
    # Proved, but not recordable — or recordable here and not yet anywhere else. Each carries the
    # manifest that names the contract, because a fleet has many and "this address is broken" otherwise
    # sends the reader to grep for it.
    refused: list[tuple[str, str, str, str]] = []
    unpushed: list[tuple[str, str, str, str]] = []
    unproven: list[tuple[str, str, str, str]] = []
    # Which contracts have already been compared against each build (keyed by `build_id`), and which
    # commit first carried that build - so a skip can say what it duplicates rather than leaving a gap
    # in the numbering that reads like a contract being dropped.
    compared: dict[str, set[str]] = {}
    claimed_by: dict[str, str] = {}
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
            fresh = still_to_compare(compared, identity, looking)
            if not fresh:
                say(1, f"{place}  same build inputs as {claimed_by[identity][:10]}, already compared — skipped")
                continue
            claimed_by.setdefault(identity, commit)
            waiting = f"{len(fresh)} waiting"
            if len(fresh) != len(looking):
                waiting += f" ({len(looking) - len(fresh)} already compared against these inputs)"
            say(1, f"{place}  {waiting}, building…", flush=True)
            started = time.monotonic()
            outcome = _try_commit(root, commit, {k: looking[k] for k in fresh}, say)
            built += 1
            # At the default level the per-commit lines are hidden, so a long stretch of builds that
            # match nothing would print nothing at all - which is the silence C3 hid behind. A line
            # every half minute keeps the run legible without becoming the flood `-v` is for.
            if arguments.verbose == 0 and time.monotonic() - beat > 30:
                beat = time.monotonic()
                elapsed = int(time.monotonic() - opened)
                print(
                    f"  … {built} builds, {recovered} recorded, {len(pending)} still looking,"
                    f" {elapsed // 60}m{elapsed % 60:02d}s elapsed",
                    flush=True,
                )
            say(1, f"{' ' * len(place)}  {time.monotonic() - started:.1f}s, {len(outcome)} matched")
            for entry_key, (found, source, declared, artefact, immutables) in outcome.items():
                wants = pending.pop(entry_key)
                entry = wants.entry
                creation = bytes.fromhex(artefact["bytecode"]["object"][2:])
                made = commit_timestamp(root, found)
                print(f"    MATCHES {entry.chain}/{entry.address}  {entry.name}")
                print(f"      built from {source} at {found[:10]}, committed {made or 'unknown'}")
                if declared != entry.name:
                    # Said out loud because it changes what the baseline means: the manifest's name is
                    # today's, and this is what the contract was called when it was deployed.
                    say(2, f"      NOTE: declared {declared} there — renamed to {entry.name} since")
                # The screen above ignored the immutables. Run the constructor and compare what it
                # actually produces, so they are IN the verdict rather than excluded from it.
                immutable_regions = artefact["deployedBytecode"].get("immutableReferences") or {}
                produced = _construct(artefact["bytecode"]["object"], entry.chain, wants.block)
                if produced is None:
                    print(f"      NOT RECORDED: the constructor could not be run at block {wants.block},")
                    print("      so the immutables cannot be checked and the match is unproven")
                    unproven.append((entry_key, entry.name, entry.manifest, found))
                    continue
                explained, unexplained = differences(
                    strip_metadata(wants.onchain), strip_metadata(produced), immutable_regions, entry.address
                )
                if unexplained:
                    print("      NOT RECORDED: the constructor does not reproduce what is deployed —")
                    for line in unexplained:
                        print(f"        {line}")
                    unproven.append((entry_key, entry.name, entry.manifest, found))
                    continue
                say(2, f"      constructor reproduces the deployed code; {len(immutables)} immutables:")
                for value in immutables:
                    say(2, f"        {value}")
                for line in explained:
                    say(2, f"      {line} — differs by construction, as expected")
                if made and made > wants.deployed:
                    print(f"      NOTE: committed AFTER the {wants.deployed} deploy — it ran from an uncommitted tree")
                # A baseline is only as good as the commit it names, and a commit on NO branch will
                # never reach a remote by any normal operation - `git push` pushes branches. Refused
                # here rather than left to the check, because `git stash drop` can destroy it before
                # any check runs.
                reach = commit_reach(root, found)
                if reach == "none":
                    print(f"      REFUSED: {found[:10]} is on no branch, so no remote can ever have it.")
                    print("      It is the only source for this deployment — put it on a branch and push it:")
                    print(f"        git branch deployed/{entry.name} {found}")
                    print(f"        git push origin deployed/{entry.name}")
                    refused.append((entry_key, entry.name, entry.manifest, found))
                    continue
                if reach == "local":
                    unpushed.append((entry_key, entry.name, entry.manifest, found))
                # What the commit alone does not settle, taken from the build that just proved it.
                # solc writes its own metadata into the artefact, so the compiler and the settings are
                # the ones that produced this bytecode rather than a second reading of foundry.toml,
                # and `sources` there is the closure it actually read.
                metadata = artefact["metadata"]
                baselines = add(
                    baselines,
                    Baseline(
                        chainId=entry.chain_id,
                        chain=entry.chain,
                        address=entry.address,
                        contractType=entry.name,
                        source=source,
                        commit=found,
                        commitTimestamp=made or "",
                        deployBlock=wants.block,
                        deployTimestamp=wants.deployed,
                        creationBytecodeKeccak256=_keccak256(creation),
                        compiler=metadata["compiler"]["version"],
                        # `compilationTarget` is `source` and `contractType` said again.
                        settings={
                            name: value for name, value in metadata["settings"].items() if name != "compilationTarget"
                        },
                        sources=source_blobs(root, found, metadata["sources"]),
                        submodules=submodule_commits(root, found),
                    ),
                )
                recovered += 1
                # Saved as each is proved rather than at the end: these runs are long enough to be
                # interrupted, and each baseline is an independent fact with nothing spanning them.
                if arguments.write:
                    write_baselines(root, baselines)

    if pending:
        print(f"\n{len(pending)} not recovered — no candidate built what is deployed:")
        for entry_key, wants in pending.items():
            print(
                f"  {entry_key}  {wants.entry.name}  "
                f"({sum(1 for seen in compared.values() if entry_key in seen)} distinct builds compared)"
            )

    if refused:
        print(f"\n{len(refused)} proved but NOT recorded — the commit is on no branch, so no remote can have it:")
        for entry_key, name, _, found in refused:
            print(f"  {entry_key}  {name}  at {found[:10]}")
        print("  Put each on a branch and push it, then run again. Until then these are unrecoverable:")
        print("  a stash entry is destroyed by `git stash drop`, and nothing else built this bytecode.")

    if unproven:
        print(f"\n{len(unproven)} screened but NOT recorded — the constructor does not account for them:")
        for entry_key, name, _, found in unproven:
            print(f"  {entry_key}  {name}  at {found[:10]}")
        print("  The code outside the immutables matches, so the source is close — but an immutable")
        print("  the source determines came out differently, which a masked comparison would have hidden.")

    if unpushed:
        # Said at the end rather than per contract: the record and the commits it names have to reach
        # the remote TOGETHER, and pushing deployed.json alone is the mistake this prevents.
        print(f"\n{len(unpushed)} recorded at commits no remote has yet:")
        for entry_key, name, _, found in unpushed:
            print(f"  {entry_key}  {name}  at {found[:10]}")
        print("  Push the branches holding them BEFORE pushing deployed.json, or the record names")
        print("  commits nobody else can resolve. CI rejects a record in that state.")

    # Everything that was NOT recorded, in one place, whatever stage it fell out at. The blocks above
    # carry the remedies - push the branch, look at the immutable - and this carries the completeness:
    # a reader can tell from one section how many contracts are missing and why, rather than inferring
    # it from the difference between two numbers.
    missing = [
        *dropped,
        *(
            (
                entry_key,
                wants.entry.name,
                wants.entry.manifest,
                f"no candidate built what is deployed (deployed {wants.deployed}, compared against "
                f"{sum(1 for seen in compared.values() if entry_key in seen)} distinct build(s))",
            )
            for entry_key, wants in pending.items()
        ),
        *(
            (entry_key, name, manifest, f"proved at {found[:10]}, but that commit is on no branch")
            for entry_key, name, manifest, found in refused
        ),
        *(
            (entry_key, name, manifest, f"screened at {found[:10]}, but the constructor does not account for it")
            for entry_key, name, manifest, found in unproven
        ),
    ]
    if missing:
        print(f"\n{len(missing)} not recorded:")
        keys = max(len(entry_key) for entry_key, _, _, _ in missing)
        names = max(len(name or "(unnamed)") for _, name, _, _ in missing)
        manifests = max(len(manifest) for _, _, manifest, _ in missing)
        for entry_key, name, manifest, reason in sorted(missing):
            print(f"  {entry_key:<{keys}}  {name or '(unnamed)':<{names}}  {manifest:<{manifests}}  {reason}")
        # What was searched, said once rather than per row: `all_commits` is `git log --all`, so an
        # unmerged branch and a stash are both in it, and "nothing built it" means nothing in ANY of
        # them did - which is a different statement from "nothing on this branch did".
        print(f"  searched {len(dated)} commit(s) from every ref, {dated[-1][1]} to {dated[0][1]}")

    print(f"\n{recovered} of {len(outstanding)} recovered, from {built} build(s) over {len(dated)} candidate commits")
    if recovered and arguments.write:
        print(f"deployed.json holds {len(baselines)} baseline(s)")
    elif recovered:
        print("not written; pass --write to record them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
