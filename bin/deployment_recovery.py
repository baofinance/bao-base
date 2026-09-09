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
import re
import subprocess
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path


def strip_metadata(code: bytes) -> bytes:
    """`code` without its CBOR metadata trailer.

    Solidity appends the trailer and then two bytes giving its length, so it removes itself exactly -
    documented at https://docs.soliditylang.org/en/latest/metadata.html ("the last two bytes in the
    bytecode indicate the length of the CBOR encoded information"). The docs describe the trailer and
    say nothing about what precedes it, which is where the byte that broke this comparison lives; see
    `matches`.
    A deployed contract carries one and a build with `FOUNDRY_CBOR_METADATA=false` does not - the real
    recovery differed by precisely those 53 bytes until this was applied, which is the first thing
    anyone repeating this will hit.

    Two guards, both HERE, where the decision is made, rather than left to a length comparison
    somewhere downstream - mitigation at a distance is not correctness:

    - a declared length that cannot fit is not applied, or the whole contract is stripped and an empty
      comparison against empty reads as a match;
    - the byte the length points at must begin a CBOR MAP (`0xa0 | n`, and solidity emits two or three
      entries), or real code whose final bytes happen to read as a plausible length loses that many
      bytes off its end."""
    if len(code) < 2:
        return code
    declared = int.from_bytes(code[-2:], "big")
    if declared + 2 > len(code):
        return code
    start = len(code) - declared - 2
    if not 0xA0 <= code[start] <= 0xAF:
        return code
    return code[:start]


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


# What a build reads. Used to DEDUPE work, never to exclude a candidate: a commit touching none of
# these cannot change any bytecode, but it is still a tree someone may have deployed from, and
# excluding it loses the true answer to save a build. `BaoPauser_v1` was deployed from a commit whose
# only change was to `bin/coverage`, and filtering it out recorded a two-month-older commit that
# happened to compile identically - equivalent bytecode, wrong provenance.
_BUILD_INPUTS = ["src", "lib", "foundry.toml", "remappings.txt", ".gitmodules", "foundry.lock"]


def build_fingerprint(repo_root: Path, commit: str) -> str:
    """What a build at `commit` would read, as one value.

    Two commits with the same fingerprint compile to the same bytecode, so the second need not be
    built - which is where the saving is, without any candidate being dropped. Tree object ids, so git
    does the hashing and an unchanged directory costs nothing to compare."""
    done = subprocess.run(
        ["git", "ls-tree", commit, "--", *_BUILD_INPUTS], cwd=repo_root, capture_output=True, text=True
    )
    return done.stdout


def candidate_commits(
    repo_root: Path, deployed_at: str, before_days: int = 120, after_days: int = 30
) -> list[str]:
    """Commits that might hold the deployed source, likeliest first.

    ONE guess is not enough - ten of the aggregators' contracts built cleanly at the last commit
    before their deploy and did not match. The order encodes what the measurements showed:

    1. The last commit BEFORE the deploy: the tree that was checked out when forge ran.
    2. Progressively earlier ones: the deploy may have run from a tree behind the tip.
    3. Then the commits AFTER it, oldest first: a deploy from a DIRTY tree has its source committed
       afterwards, which is exactly what bao-base's own pauser did three days later.

    BOUNDED BY TIME, not by a count. `--limit 12` was a number with nothing behind it, and not even
    the binding constraint - twelve commits already reached two months back in the aggregators. A
    window says what it means.

    NOT narrowed to commits that touch a build input, though the saving would be large. A commit that
    changes nothing a build reads is still a tree someone deployed from: `BaoPauser_v1` was deployed
    from one whose only change was `bin/coverage`, and excluding it recorded a two-month-older commit
    that compiled identically - right bytecode, wrong provenance. `build_fingerprint` deduplicates the
    WORK instead, which saves the same builds and drops no candidate.

    NOT `--first-parent`. It was, on the reasoning that a deploy runs from a point on the main line -
    and that is simply false: deploys run from whatever is checked out, which is often a feature
    branch. The arbitrum aggregators were deployed from `l2feeds`, whose tip carried "Remove BASE_NAME
    storage from Arbitrum and Base oracles", exactly the change that decides their bytecode.
    `--first-parent` offered 11 commits in a window holding 63, and none of them could have built what
    is on chain."""
    deployed = datetime.fromisoformat(deployed_at.replace("Z", "+00:00"))

    def line(*extra: str) -> list[str]:
        done = subprocess.run(
            ["git", "log", "--format=%H", *extra],
            cwd=repo_root,
            capture_output=True,
            text=True,
        )
        return [c for c in done.stdout.split() if c]

    def stamp(days: int) -> str:
        return (deployed + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S%z")

    before = line("--before", deployed_at, "--since", stamp(-before_days))
    after = list(reversed(line("--since", deployed_at, "--before", stamp(after_days))))
    return before + after


def creation_block(has_code: Callable[[int], bool], upper: int, floor: int = 0) -> int | None:
    """The first block at which the contract's code exists, or None if it cannot be bracketed.

    `upper` is a block KNOWN to have the code, and in practice a close one: the manifest's
    `deploymentTime` is the deploy script's clock written after the broadcast, so a block found from
    it always sits just past the answer - fifteen blocks past, for BaoPauser, whose manifest was 2m55s
    late. Walking back in doubling steps from a close bound and then bisecting costs a handful of
    calls; bisecting the whole chain blindly costs about twenty-five.

    None rather than a guess in both failure modes: if `upper` has no code the answer is above the
    range, and if even `floor` has code it is below. Returning either bound would record a block the
    contract did not exist at."""
    if not has_code(upper):
        return None
    low, step = upper, 1
    while low > floor:
        low = max(floor, upper - step)
        if not has_code(low):
            break
        step *= 2
    else:
        return None
    if has_code(low):
        return None
    while upper - low > 1:
        middle = (low + upper) // 2
        if has_code(middle):
            upper = middle
        else:
            low = middle
    return upper


def commit_timestamp(repo_root: Path, commit: str) -> str | None:
    """When `commit` was made, in UTC.

    From Unix seconds rather than `%cI`, which carries the committer's local offset - two identical
    commits made in different zones would otherwise record differently, and a record of facts should
    not depend on where someone was sitting."""
    done = subprocess.run(["git", "log", "-1", "--format=%ct", commit], cwd=repo_root, capture_output=True, text=True)
    seconds = done.stdout.strip()
    if not seconds.isdigit():
        return None
    return datetime.fromtimestamp(int(seconds), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def source_at(repo_root: Path, commit: str, contract_type: str) -> str | None:
    """Where the file defining `contract_type` lived at `commit`, or None if it is not there.

    NOT the recorded path: that is the path at DEPLOY time, and a candidate commit may predate a move.
    `v3-oracles.json` records `src/Aggregator_…` where the tree later held `src/mainnet/Aggregator_…`,
    and building the recorded path against an older commit produced "No source files found" forty
    times. The contract NAME is what survives a move, so the file is located in that commit's own tree.

    `lib/` is searched like anywhere else: a contract defined in a dependency is defined there, and
    nothing about the directory makes it a different kind of source. That is also why this greps the
    commit in ONE call rather than reading files - the closure includes every submodule, and a `git
    show` per file would be thousands of processes.

    The DECLARATION decides, never the filename: a `Foo.sol` holding `contract Bar` must not answer
    for `Foo`. A basename match only breaks a tie between two files that both declare it, and if that
    leaves two, the answer is None - two files declaring one name is the flat-namespace problem this
    fleet already has (three such names at HEAD, none of them deployed), and picking one would be
    arbitrary."""
    found = subprocess.run(
        [
            "git",
            "grep",
            "-l",
            "--extended-regexp",
            rf"^[[:space:]]*(abstract[[:space:]]+)?contract[[:space:]]+{re.escape(contract_type)}\b",
            commit,
            "--",
            "*.sol",
        ],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    declaring = [line.split(":", 1)[1] for line in found.stdout.splitlines() if ":" in line]
    if len(declaring) == 1:
        return declaring[0]
    named = [p for p in declaring if p.rsplit("/", 1)[-1] == f"{contract_type}.sol"]
    return named[0] if len(named) == 1 else None


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
    artefact's own statement of which file it came from, so it cannot be confused by a shared name.

    EQUALITY, not a suffix. `endswith` looked safe and is not: `src/XFoo.sol` does not match
    `src/Foo.sol`, but `myssrc/Foo.sol` does, and so does a vendored `lib/dep/src/Foo.sol`. This
    decides which bytecode a baseline is compared against.

    More than one claimant returns None. Either would be arbitrary, and arbitrary here means comparing
    a deployed contract against a different contract's build."""
    claiming = []
    for candidate in out.rglob(f"{contract_type}.json"):
        try:
            artefact = json.loads(candidate.read_text())
        except json.JSONDecodeError:
            continue
        targets = (artefact.get("metadata") or {}).get("settings", {}).get("compilationTarget") or {}
        if targets.get(source) == contract_type:
            claiming.append(artefact)
    return claiming[0] if len(claiming) == 1 else None


def matches(onchain: bytes, artefact: dict) -> tuple[bool, list[str]]:
    """Whether the deployed runtime code is what this artefact builds, and the immutables read off it.

    BOTH SIDES ARE STRIPPED. A build carries its own CBOR trailer and it never equals the deployed
    one, because each hashes the sources and settings of the tree it was built in - so the verdict has
    to rest on the code with both removed. Stripping only the chain's side happened to work while the
    build was forced to emit no metadata, and forcing that was itself the defect: whether the metadata
    is appended changes the CODE BEFORE IT. The compiler emits a terminator only when there is
    something after the code to separate from - ethereum/solidity, `libevmasm/Assembly.cpp`, in
    `assemble()` (https://raw.githubusercontent.com/ethereum/solidity/develop/libevmasm/Assembly.cpp;
    `develop` moves, so `git grep "help tests find miscompilation"` is the durable way to find it):

        if (!m_subs.empty() || !m_data.empty() || !m_auxiliaryData.empty())
            // Append an INVALID here to help tests find miscompilation.
            ret.bytecode.push_back(static_cast<uint8_t>(Instruction::INVALID));

    The CBOR metadata IS that auxiliary data, so a contract with no sub-assemblies and no data section
    loses the `INVALID` along with it, leaving the metadata-off build one byte shorter than anything
    that was ever deployed. Measured on `Aggregator_stETH_USD_mainnet` at a2ac04c401 - one source, one
    compiler: 3302 bytes with metadata off, 3303 after stripping with it on, 3303 deployed.

    The immutables are returned rather than discarded: they are excluded from the comparison, so they
    are the part a human still has to look at - and for the aggregators they are the Chainlink feed
    addresses, which is exactly the thing an audit is about."""
    # The regions are offsets from the START, and the trailer is at the end, so stripping moves none
    # of them.
    built = strip_metadata(bytes.fromhex(artefact["deployedBytecode"]["object"][2:]))
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
