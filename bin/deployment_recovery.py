#!/usr/bin/env python3
"""Recover the commit a deployed contract was built from, and prove it against the chain.

Every repository's baselines were lost or never recorded, so this is how they come back: 307 entries
across the fleet, of which one is done. The method was established by hand on `BaoPauser_v1` and is
mechanised here, because a recovery run by hand proves one contract and nothing about the next.

FOUR STEPS, of which only the first is guesswork:

1. **Candidate** - the last commit before the deployment timestamp. The commit that RECORDS a deploy
   lands days AFTER it (measured: two days, for the pauser), and the source is often edited after that
   too, so "the commit that mentions this contract" is the wrong answer and the tag is the wrong
   answer.
2. **Build it** - a worktree at that commit, with every submodule placed at THAT commit's gitlink,
   recursively. This cannot be shortcut by copying a guessed set of files: the closure reaches nested
   submodules, and only forge knows which are reachable.
3. **Compare with the chain** - the deployed runtime code, minus its CBOR metadata trailer, with the
   artefact's declared immutable regions masked on both sides.
4. **Record it** - but only on a match. A candidate that does not match is reported, never written:
   an unrecovered baseline is a known gap, and a wrong one is a lie that everything downstream trusts.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


def strip_metadata(code: bytes) -> bytes:
    """`code` without its CBOR metadata trailer.

    Solidity appends the trailer and then two bytes giving its length, so it removes itself exactly.
    A deployed contract carries one and a build with `FOUNDRY_CBOR_METADATA=false` does not - the real
    recovery differed by precisely those 53 bytes until this was applied, which is the first thing
    anyone repeating this will hit.

    A declared length that cannot fit is left alone rather than applied: stripping everything would
    compare empty against empty and call it a match, which is the worst answer available."""
    if len(code) < 2:
        return code
    declared = int.from_bytes(code[-2:], "big")
    if declared + 2 > len(code):
        return code
    return code[: -(declared + 2)]


def mask_immutables(code: bytes, references: dict) -> bytes:
    """`code` with each declared immutable region zeroed.

    An immutable is written into the runtime code at construction, so the built artefact has zeros
    where the chain has a value. Masking both sides is what leaves the rest comparable. The regions
    come from the artefact's own `immutableReferences`, never from a guess - masking too widely is how
    a comparison starts accepting contracts it should reject, and the aggregators' immutables ARE
    their feed addresses, so what is masked must be reported beside the verdict rather than forgotten.
    """
    masked = bytearray(code)
    for regions in references.values():
        for region in regions:
            start, length = region["start"], region["length"]
            masked[start : start + length] = b"\x00" * length
    return bytes(masked)


def candidate_commit(repo_root: Path, deployed_at: str) -> str | None:
    """The commit that was HEAD when the deploy ran, or None if the repository is younger than it.

    `--first-parent` so a merged branch's commits cannot be picked: what was checked out at the moment
    of the deploy was a point on the main line. None rather than the oldest commit, because handing
    back something arbitrary would see it recorded as a baseline and believed."""
    done = subprocess.run(
        ["git", "log", "--first-parent", "--format=%H", "--before", deployed_at, "-1"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    found = done.stdout.strip()
    return found or None


def place_worktree(repo_root: Path, commit: str, at: Path) -> list[str]:
    """A checkout of `commit` at `at`, with every submodule at its recorded gitlink. Returns failures.

    Recursive, because the closure reaches nested submodules - the OpenZeppelin contracts live inside
    contracts-upgradeable, and a build without them does not fail cleanly, it fails as an unresolved
    import a long way from the cause.

    A submodule that cannot be placed is REPORTED rather than fatal: it may not be in the closure at
    all (`solidity-stringutils` was not, in the real recovery), and a build that needs it fails loudly
    naming the file, which is actionable. Guessing which are needed and placing too few is the failure
    that is silent."""
    failures: list[str] = []
    subprocess.run(
        ["git", "worktree", "add", "--detach", "--quiet", str(at), commit],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )

    def place(parent_repo: Path, parent_commit: str, parent_at: Path, prefix: str) -> None:
        listing = subprocess.run(
            ["git", "ls-tree", parent_commit, "lib/"], cwd=parent_repo, capture_output=True, text=True
        )
        for line in listing.stdout.splitlines():
            fields = line.split()
            if len(fields) < 4 or fields[1] != "commit":
                continue
            gitlink, path = fields[2], fields[3]
            target = parent_at / path
            # A submodule the parent records but that is not checked out HERE has no object store to
            # take a worktree from. Reported rather than raised: it may not be in the closure at all,
            # and the build says so loudly if it is.
            if not (parent_repo / path).is_dir():
                failures.append(f"{prefix}{path}@{gitlink[:10]} (not checked out)")
                continue
            if target.exists() and not any(target.iterdir()):
                target.rmdir()
            done = subprocess.run(
                ["git", "worktree", "add", "--detach", "--quiet", str(target), gitlink],
                cwd=parent_repo / path,
                capture_output=True,
                text=True,
            )
            if done.returncode != 0:
                failures.append(f"{prefix}{path}@{gitlink[:10]}")
                continue
            place(parent_repo / path, gitlink, target, f"{prefix}{path}/")

    place(repo_root, commit, at, "")
    return failures


def remove_worktree(repo_root: Path, at: Path) -> None:
    """Undo `place_worktree`, deepest first so a parent is never removed from under a child.

    `prune --expire=now` afterwards because a bare prune honours `gc.worktreePruneExpire`, three
    months by default, which would leave the administrative files behind in every repository this
    touched."""
    for gitdir in sorted(at.rglob(".git"), key=lambda p: len(p.parts), reverse=True):
        subprocess.run(
            ["git", "worktree", "remove", "--force", str(gitdir.parent)],
            cwd=gitdir.parent,
            capture_output=True,
            text=True,
        )
    subprocess.run(["git", "worktree", "remove", "--force", str(at)], cwd=repo_root, capture_output=True, text=True)
    for repo in [repo_root, *(p.parent for p in repo_root.glob("lib/*/.git"))]:
        subprocess.run(["git", "worktree", "prune", "--expire=now"], cwd=repo, capture_output=True, text=True)


def artefact_for(out: Path, source: str, contract_type: str) -> dict | None:
    """The compiled artefact for one contract, located by the source path it declares.

    Not by `out/<basename>.sol/`, which is a flat namespace this fleet already collides in - two
    different `Aggregator_stETH_USD` contracts live in one build tree. `compilationTarget` is the
    artefact's own statement of which file it came from, so it cannot be confused by a shared name."""
    for candidate in out.rglob(f"{contract_type}.json"):
        try:
            artefact = json.loads(candidate.read_text())
        except json.JSONDecodeError:
            continue
        targets = (artefact.get("metadata") or {}).get("settings", {}).get("compilationTarget") or {}
        if any(path.endswith(source) and name == contract_type for path, name in targets.items()):
            return artefact
    return None


def matches(onchain: bytes, artefact: dict) -> tuple[bool, list[str]]:
    """Whether the deployed runtime code is what this artefact builds, and the immutables read off it.

    The immutables are returned rather than discarded: they are excluded from the comparison, so they
    are the part a human still has to look at - and for the aggregators they are the Chainlink feed
    addresses, which is exactly the thing an audit is about."""
    built = bytes.fromhex(artefact["deployedBytecode"]["object"][2:])
    references = artefact["deployedBytecode"].get("immutableReferences") or {}
    stripped = strip_metadata(onchain)
    if len(stripped) != len(built):
        return False, []
    values = [
        "0x" + stripped[region["start"] : region["start"] + region["length"]].hex()
        for regions in references.values()
        for region in regions[:1]
    ]
    return mask_immutables(stripped, references) == mask_immutables(built, references), values
