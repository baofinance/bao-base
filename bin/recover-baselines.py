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
from pathlib import Path

from deployment_baselines import Baseline, add, read_baselines, review, write_baselines
from deployment_recovery import (
    artefact_for,
    candidate_commits,
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


def _build(worktree: Path, source: str, out: Path) -> bool:
    """Compile one source file and its closure, with metadata off so the comparison can be made."""
    done = subprocess.run(
        ["forge", "build", source],
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


def _search(root: Path, deployed_at: str, contract_type: str, onchain: bytes, limit: int):
    """The first candidate commit whose build is what is deployed, or None with the reasons printed.

    Each candidate is tried in full - locate, place, build, compare - because a commit that cannot
    build or does not hold the contract says nothing about the next one. The reasons are counted
    rather than printed per candidate: twelve lines saying "does not build" for one contract buries
    the one line that matters."""
    why: dict[str, int] = {}
    for commit in candidate_commits(root, deployed_at, limit):
        source = source_at(root, commit, contract_type)
        if source is None:
            why["not in that tree"] = why.get("not in that tree", 0) + 1
            continue
        with tempfile.TemporaryDirectory(prefix="recover-baseline-") as scratch:
            worktree, out = Path(scratch) / "wt", Path(scratch) / "out"
            place_worktree(root, commit, worktree)
            try:
                if not _build(worktree, source, out):
                    why["does not build"] = why.get("does not build", 0) + 1
                    continue
                artefact = artefact_for(out, source, contract_type)
                if artefact is None:
                    why["built, no such artefact"] = why.get("built, no such artefact", 0) + 1
                    continue
                agreed, immutables = matches(onchain, artefact)
                if agreed:
                    return commit, source, artefact, immutables
                why["bytecode differs"] = why.get("bytecode differs", 0) + 1
            finally:
                remove_worktree(root, worktree)
    print("  no candidate matches: " + ", ".join(f"{n}x {reason}" for reason, n in why.items()))
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="record the baselines that verify (default: report)")
    parser.add_argument("--only", help="recover just this address")
    parser.add_argument(
        "--limit", type=int, default=12, help="candidate commits to try each side of the deploy (default 12)"
    )
    arguments = parser.parse_args()

    root = Path.cwd()
    found = review(root)
    outstanding = [e for e in found.unrecovered if not arguments.only or e.address.lower() == arguments.only.lower()]
    if not outstanding:
        print("nothing to recover")
        return 0

    baselines = read_baselines(root)
    recovered = 0
    for entry in outstanding:
        print(f"{entry.chain}/{entry.address}  {entry.name}")
        if not entry.deployed_at:
            print("  no deployment time recorded, so no candidate commit can be chosen")
            continue
        if not entry.name:
            print("  the manifest names no contract, so nothing can be located or built")
            continue
        onchain = _deployed_code(entry.address, entry.chain)
        if onchain is None:
            print(f"  could not read the deployed code over the {entry.chain} RPC")
            continue

        found = _search(root, entry.deployed_at, entry.name, onchain, arguments.limit)
        if found is None:
            continue
        commit, source, artefact, immutables = found
        creation = bytes.fromhex(artefact["bytecode"]["object"][2:])
        print(f"  MATCHES at {commit[:10]} ({source}); immutables on chain: {' '.join(immutables) or 'none'}")
        baselines = add(
            baselines,
            Baseline(
                chain=entry.chain,
                address=entry.address,
                contract_type=entry.name,
                source=source,
                commit=commit,
                creation_bytecode_hash="sha256:" + hashlib.sha256(creation).hexdigest(),
            ),
        )
        recovered += 1

    print(f"\n{recovered} of {len(outstanding)} recovered")
    if recovered and arguments.write:
        write_baselines(root, baselines)
        print(f"written to deployed.json — {len(baselines)} baseline(s)")
    elif recovered:
        print("not written; pass --write to record them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
