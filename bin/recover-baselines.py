#!/usr/bin/env python3
"""Recover the source commit of every deployed contract that has no baseline, and prove it on chain.

Reports by default and writes only when told to, like `yarn update --check`: a baseline is believed by
everything downstream, so writing one is a deliberate act.

A contract is recorded ONLY when the commit's build matches the deployed code. A candidate that does
not match is reported and skipped - an unrecovered baseline is a known gap, and a wrong one is a lie.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from dataclasses import dataclass

from deployment_baselines import Baseline, add, key, read_baselines, review, write_baselines
from deployment_recovery import (
    artefact_for,
    build_fingerprint,
    candidate_commits,
    commit_timestamp,
    creation_block,
    matches,
    place_worktree,
    remove_worktree,
    source_at,
)

_METADATA_OFF = {"FOUNDRY_BYTECODE_HASH": "none", "FOUNDRY_CBOR_METADATA": "false"}


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


def _build(worktree: Path, sources: list[str], out: Path) -> bool:
    """Compile these source files and their closure, with metadata off so comparisons can be made.

    Several at once because they share the closure: twenty aggregators at one commit compile their
    common base and libraries once between them rather than twenty times."""
    done = subprocess.run(
        ["forge", "build", *sources],
        cwd=worktree,
        capture_output=True,
        text=True,
        env={**_environment(), **_METADATA_OFF, "FOUNDRY_OUT": str(out)},
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
    candidates: list[str]


def _dated(root: Path, commits: set[str]) -> list[tuple[str, str]]:
    """(commit, its UTC timestamp) for each, newest first. One `git log`, not a call each."""
    done = subprocess.run(
        ["git", "log", "--format=%H %ct", "--no-walk", *commits], cwd=root, capture_output=True, text=True
    )
    dated = []
    for line in done.stdout.splitlines():
        commit, _, seconds = line.partition(" ")
        if commit in commits and seconds.isdigit():
            dated.append((commit, datetime.fromtimestamp(int(seconds), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")))
    return dated


def _try_commit(root: Path, commit: str, pending: dict[str, _Wanted]) -> dict[str, tuple]:
    """Build ONE worktree at `commit` and compare every contract that is looking there.

    This is the whole point of grouping. Twenty arbitrum aggregators share a deploy and therefore share
    candidates; building the closure once per (contract, commit) made 44 candidates into 880 builds,
    where one build per commit makes it 44. Nothing about the answer changes - only how many times the
    same compilation is repeated."""
    looking = {k: source_at(root, commit, w.entry.name) for k, w in pending.items() if commit in w.candidates}
    sources = {k: s for k, s in looking.items() if s}
    if not sources:
        return {}
    with tempfile.TemporaryDirectory(prefix="recover-baseline-") as scratch:
        worktree, out = Path(scratch) / "wt", Path(scratch) / "out"
        missing = place_worktree(root, commit, worktree)
        try:
            if not _build(worktree, sorted(set(sources.values())), out):
                # Named here because a build failing right after something could not be placed is
                # almost always that, and reporting only "does not build" sends the reader nowhere.
                if missing:
                    print(f"  {commit[:10]}: build failed, and these were not placed: {' '.join(missing)}")
                return {}
            found = {}
            for entry_key, source in sources.items():
                artefact = artefact_for(out, source, pending[entry_key].entry.name)
                if artefact is None:
                    continue
                agreed, immutables = matches(pending[entry_key].onchain, artefact)
                if agreed:
                    found[entry_key] = (commit, source, artefact, immutables)
            return found
        finally:
            remove_worktree(root, worktree)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="record the baselines that verify (default: report)")
    parser.add_argument("--only", help="recover just this address")
    parser.add_argument("--before-days", type=int, default=120, help="how far before the deploy to look")
    parser.add_argument("--after-days", type=int, default=30, help="how far after, for a dirty-tree deploy")
    arguments = parser.parse_args()

    root = Path.cwd()
    found = review(root)
    outstanding = [e for e in found.unrecovered if not arguments.only or e.address.lower() == arguments.only.lower()]
    if not outstanding:
        print("nothing to recover")
        return 0

    baselines = read_baselines(root)

    # Every contract's chain facts first, because they decide its candidate window and cost only RPC.
    pending: dict[str, _Wanted] = {}
    for entry in outstanding:
        print(f"{entry.chain}/{entry.address}  {entry.name}")
        if not entry.name:
            print("  the manifest names no contract, so nothing can be located or built")
            continue
        if not entry.deployed_at:
            print("  no deployment time recorded, so the window cannot be placed")
            continue
        onchain = _deployed_code(entry.address, entry.chain)
        if onchain is None:
            print(f"  could not read the deployed code over the {entry.chain} RPC")
            continue
        deployment = _deployment(entry.address, entry.chain, entry.deployed_at)
        if deployment is None:
            print(f"  could not find the block it was created in over the {entry.chain} RPC")
            continue
        block, deployed = deployment
        # The chain's timestamp, not the manifest's, anchors the window: the manifest's is the deploy
        # script's clock and is late, so it opens the search in the wrong place.
        candidates = candidate_commits(root, deployed, arguments.before_days, arguments.after_days)
        print(f"  created in block {block} at {deployed}; {len(candidates)} candidate commits")
        pending[key(entry.chain, entry.address)] = _Wanted(entry, onchain, block, deployed, candidates)

    # THE DEPLOY BLOCK DECIDES WHICH COMMIT, not the order things happen to be tried in. Many commits
    # compile identically, so "the first that matches" is arbitrary; "the LATEST at or before the
    # moment the contract was created" is the tree that was actually checked out, and is unique.
    #
    # So: newest first, accepting only commits at or before each contract's deploy. Whatever is still
    # unmatched then had no committed source at deploy time - a dirty tree - and takes the EARLIEST
    # commit after it, which is where that source first landed.
    dated = _dated(root, {c for w in pending.values() for c in w.candidates})
    passes = [
        ("at or before the deploy", dated, lambda when, deployed: when <= deployed),
        ("after it (an uncommitted tree)", list(reversed(dated)), lambda when, deployed: when > deployed),
    ]
    print(f"\ntrying {len(dated)} commits for {len(pending)} contracts\n")
    recovered = 0
    tried: set[str] = set()
    for _, order, admits in passes:
        for commit, when in order:
            if not pending:
                break
            looking = {k: w for k, w in pending.items() if commit in w.candidates and admits(when, w.deployed)}
            if not looking:
                continue
            # Two commits reading the same build inputs compile the same, so the second is free.
            print_key = build_fingerprint(root, commit)
            if print_key in tried:
                continue
            tried.add(print_key)
            for entry_key, (found, source, artefact, immutables) in _try_commit(root, commit, looking).items():
                wants = pending.pop(entry_key)
                entry = wants.entry
                creation = bytes.fromhex(artefact["bytecode"]["object"][2:])
                made = commit_timestamp(root, found)
                print(f"{entry.chain}/{entry.address}  {entry.name}")
                print(f"  MATCHES at {found[:10]} ({source}); immutables: {' '.join(immutables) or 'none'}")
                if made and made > wants.deployed:
                    print(f"  NOTE: committed at {made}, AFTER the deploy — it ran from an uncommitted tree")
                baselines = add(
                    baselines,
                    Baseline(
                        chain=entry.chain,
                        address=entry.address,
                        contract_type=entry.name,
                        source=source,
                        commit=found,
                        commit_timestamp=made or "",
                        deploy_block=wants.block,
                        deploy_timestamp=wants.deployed,
                        creation_bytecode_hash="sha256:" + hashlib.sha256(creation).hexdigest(),
                    ),
                )
                recovered += 1
                # Saved as each is proved rather than at the end: these runs are long enough to be
                # interrupted, and each baseline is an independent fact with nothing spanning them.
                if arguments.write:
                    write_baselines(root, baselines)

    for entry_key, wants in pending.items():
        print(f"{entry_key}  {wants.entry.name}: no candidate built what is deployed")

    print(f"\n{recovered} of {len(outstanding)} recovered")
    if recovered and arguments.write:
        print(f"deployed.json holds {len(baselines)} baseline(s)")
    elif recovered:
        print("not written; pass --write to record them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
