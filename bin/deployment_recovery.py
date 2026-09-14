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

import io
import json
import re
import subprocess
import tarfile
from collections.abc import Callable, Iterable
from datetime import UTC, datetime
from pathlib import Path


def strip_metadata(code: bytes) -> bytes:
    """`code` without its CBOR metadata trailer.

    Solidity appends the trailer and then two bytes giving its length, so it removes itself exactly -
    documented at https://docs.soliditylang.org/en/latest/metadata.html ("the last two bytes in the
    bytecode indicate the length of the CBOR encoded information"). The docs describe the trailer and
    say nothing about what precedes it, which is where the byte that broke this comparison lives; see
    `matches`.

    Applied to BOTH sides, because both carry a trailer and the two never agree - each hashes the
    sources and settings of the tree it was built in. The real recovery differed by precisely those 53
    bytes until this was applied, which is the first thing anyone repeating this will hit.

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


def compiler_in(code: bytes) -> str | None:
    """The solc version that built `code`, read from its CBOR metadata trailer. None if it says none.

    The deployed code is the only place this is stated. A commit fixes the compiler only as far as its
    pragma and `foundry.toml` do - the aggregators pin `0.8.30` exactly, bao-base's sources mostly give
    a range - so a rebuild takes whatever version is installed and can differ from the deploy's while
    being asked to match it. Reading it here pins the rebuild to the compiler the artefact names.

    Solidity writes `{"ipfs": …, "solc": <3 bytes>}` and then the trailer's length, so the version is
    the three bytes after the key. Measured on two deployed contracts, `BaoPauser_v1` at 0xd8785d5C and
    `Aggregator_stETH_USD_mainnet` at 0x003056C3, both ending `64736f6c634300081e0033`: the key `solc`,
    a 3-byte string header `0x43`, then `00 08 1e` - 0.8.30.

    A NIGHTLY build writes a string there instead, and a contract built by one names no release: None
    is returned rather than a guess, because pinning a rebuild to the wrong compiler would be a match
    that proves nothing about what is deployed."""
    trailer = code[len(strip_metadata(code)) :]
    at = trailer.find(b"solc")
    if at < 0:
        return None
    marker = at + len(b"solc")
    # `0x43` is CBOR for "three bytes follow", which is how a RELEASE records major.minor.patch.
    if marker >= len(trailer) or trailer[marker] != 0x43 or marker + 4 > len(trailer):
        return None
    return ".".join(str(part) for part in trailer[marker + 1 : marker + 4])


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


def build_id(repo_root: Path, commit: str) -> str:
    """Everything a build at `commit` would read, as one value: the id OF THE BUILD, not of the commit.

    Two commits with the same build id compile to the same bytecode, so the second need not be built -
    which is where the saving is, without any candidate being dropped. It is derived, not assigned:
    the tree object ids of the build's inputs, so git does the hashing and an unchanged directory costs
    nothing to compare."""
    done = subprocess.run(
        ["git", "ls-tree", commit, "--", *_BUILD_INPUTS], cwd=repo_root, capture_output=True, text=True
    )
    return done.stdout


def still_to_try(tried: dict[str, set[str]], build: str, keys: Iterable[str]) -> list[str]:
    """Which of `keys` this build (a `build_id`) has not been tried for yet, claiming them.

    Two commits reading the same build inputs compile the same, so the second need not be built - but
    ONLY for the contracts the first build was actually tried for. Recording the build id alone, as a
    set of builds already done, silently drops every contract that becomes eligible later: its
    candidate window opens on a commit whose inputs were already built for somebody else, the commit is
    skipped, and the contract is reported as "no candidate built what is deployed" having never been
    compared with anything.

    Measured: `Aggregator_stETH_AAPL_arbitrum` recovers at 3a108494df in 82 candidates when run on its
    own, and was reported unrecovered in the run of 97 - one of 52 in that state. The two-pass order
    makes it worse, because the second pass skips every build id the first pass claimed.

    TRIED, not compared, and the two must not be conflated: a build is claimed here before the sources
    are looked for, and the commit may then declare the contract nowhere, fail to compile, or name a
    compiler that is not the one the chain names - in each of which nothing is built and nothing is
    compared. Claiming is still right, because a second commit with the same inputs would reach the
    same dead end; counting it as a comparison is not, and the run reported contracts as having been
    compared against every commit it had merely reached. What was actually compared is recorded by the
    caller, from what the build returns."""
    seen = tried.setdefault(build, set())
    fresh = [entry_key for entry_key in keys if entry_key not in seen]
    seen.update(fresh)
    return fresh


def all_commits(repo_root: Path) -> list[tuple[str, str]]:
    """Every commit this repository holds, newest first, each with its UTC timestamp.

    UNBOUNDED, and that is a correction. It was a time window (`--before-days 120 --after-days 30`),
    and before that `--limit 12` - a number with nothing behind it. Every version of the bound was
    wrong for the same reason: THE ERROR IS ONE-SIDED. A bound that is too narrow loses the answer and
    reports it as "no candidate built what is deployed", indistinguishable from a real miss; a bound
    that is too wide costs only time and cannot produce a wrong answer, because every match is verified
    against the deployed bytecode and the "latest at or before the deploy" rule fixes which commit wins
    however many were considered.

    And a time window measures the CALENDAR, not the repository: the same 120/30 days gave 89
    candidates around February 2026 and 23 around May, a fourfold swing in density for one window. So
    it never meant "enough candidates".

    What it bought, measured on harbor-price-aggregators: 145 commits carry 89 distinct builds; the
    150-day window covered 102 commits and 75 builds, at a mean of 1.0s a build. Searching everything
    costs FOURTEEN SECONDS more, because `build_id` bounds the work by the number of distinct builds
    in the repository rather than by the size of the window.

    ALL REFS, so an unmerged branch and a stash are both in - the arbitrum aggregators were deployed
    from `l2feeds`, and a deploy from a dirty tree that was stashed rather than committed is findable
    nowhere else.

    NOT `--first-parent`. It was, on the reasoning that a deploy runs from a point on the main line -
    and that is simply false: deploys run from whatever is checked out. `l2feeds`'s tip carried "Remove
    BASE_NAME storage from Arbitrum and Base oracles", exactly the change that decides that bytecode,
    and `--first-parent` offered 11 commits in a window holding 63, none of which could have built what
    is on chain.

    NOT narrowed to commits that touch a build input, though the saving would be large. A commit that
    changes nothing a build reads is still a tree someone deployed from: `BaoPauser_v1` was deployed
    from one whose only change was `bin/coverage`, and excluding it recorded a two-month-older commit
    that compiled identically - right bytecode, wrong provenance. `build_id` deduplicates the WORK
    instead, which saves the same builds and drops no candidate."""
    done = subprocess.run(["git", "log", "--all", "--format=%H %ct"], cwd=repo_root, capture_output=True, text=True)
    dated = []
    for line in done.stdout.splitlines():
        commit, _, seconds = line.partition(" ")
        if commit and seconds.isdigit():
            dated.append((commit, datetime.fromtimestamp(int(seconds), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")))
    return sorted(dated, key=lambda pair: pair[1], reverse=True)


def search_passes(
    dated: list[tuple[str, str]],
) -> list[tuple[str, list[tuple[str, str]], Callable[[str, str], bool]]]:
    """The two passes every contract's search is made of, over one shared list of commits.

    ONE guess is not enough - ten of the aggregators' contracts built cleanly at the last commit before
    their deploy and did not match. The order encodes what the measurements showed:

    1. The latest commit AT OR BEFORE the deploy: the tree that was checked out when forge ran.
    2. Progressively earlier ones: the deploy may have run from a tree behind the tip.
    3. Then the commits AFTER it, oldest first: a deploy from a DIRTY tree has its source committed
       afterwards - bao-base's pauser three days later, and the megaeth aggregators twelve minutes.

    Two passes over a SHARED order rather than an order per contract, because that is what lets one
    build serve every contract looking at that commit. Walking newest-first while admitting only
    commits at or before each contract's own deploy gives each of them (1) and (2) in the right order
    anyway, and the reversed second pass gives (3)."""
    return [
        ("at or before the deploy", dated, lambda when, deployed: when <= deployed),
        ("after it (an uncommitted tree)", list(reversed(dated)), lambda when, deployed: when > deployed),
    ]


def creation_block(has_code: Callable[[int], bool], *, near: int, ceiling: int, floor: int = 0) -> int | None:
    """The first block at which the contract's code exists, or None if it cannot be bracketed.

    `near` is an ESTIMATE and lands on either side of the answer. The manifest's `deploymentTime` is
    the deploy script's clock written after the broadcast, so the block found from it usually sits
    just past the creation - fifteen blocks past, for BaoPauser, whose manifest was 2m55s late. But
    two of the mainnet aggregators record a time whose block holds no code at all, so for them the
    creation is somewhere ABOVE the estimate.

    The search is therefore symmetric: double away from `near` in whichever direction the answer must
    lie until a block answers differently, then bisect the bracket that pins. From a close estimate
    that is a handful of calls, and from a distant one twice the logarithm of the distance - where a
    blind bisect of the whole chain costs about twenty-five however good the estimate was.

    None rather than a guess when the range cannot bracket it: every block down to `floor` has the
    code, so the creation is below it; or nothing up to `ceiling` - the head of the chain - has the
    code, so there is no creation to record. Returning either bound would name a block the contract
    did not exist at."""
    low = high = near
    step = 1
    if has_code(near):
        # Back towards the floor for the last block WITHOUT the code: the creation is just above it.
        while low > floor:
            low = max(floor, near - step)
            if not has_code(low):
                break
            step *= 2
        else:
            return None
    else:
        # Forward towards the head for the first block WITH it: the creation is at or below that.
        while high < ceiling:
            high = min(ceiling, near + step)
            if has_code(high):
                break
            step *= 2
        else:
            return None
    while high - low > 1:
        middle = (low + high) // 2
        if has_code(middle):
            high = middle
        else:
            low = middle
    return high


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


def declared_in(repo_root: Path, commit: str, path: str) -> str | None:
    """The single contract that `path` declares at `commit`, or None if it declares none or several.

    Several is not resolved by picking: a file declaring two contracts gives no reason to prefer
    either, and preferring wrongly means comparing a deployed contract against a different one's
    build."""
    done = subprocess.run(["git", "show", f"{commit}:{path}"], cwd=repo_root, capture_output=True, text=True)
    declared = re.findall(r"^[ \t]*(?:abstract[ \t]+)?contract[ \t]+(\w+)", done.stdout, re.MULTILINE)
    return declared[0] if len(declared) == 1 else None


def _path_at(repo_root: Path, commit: str, recorded_path: str) -> str | None:
    """What `recorded_path` was called at `commit`, following renames, or None if git knows of none.

    Git already computes this, and computes it from CONTENT similarity rather than from names - which
    is the only thing that can follow a file whose name is the very thing that changed. The megaeth
    rename comes back as `R075 …Aggregator_USDMY_ETH_megaeth.sol → …Aggregator_USDM_ETH_megaeth.sol`."""
    done = subprocess.run(
        ["git", "diff", "-M", "--name-status", commit, "HEAD"], cwd=repo_root, capture_output=True, text=True
    )
    for line in done.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and fields[0].startswith("R") and fields[2] == recorded_path:
            return fields[1]
    return None


def declaration_of(contract_type: str) -> str:
    """The line where `contract_type` is declared, as a POSIX extended regular expression.

    POSIX and not GNU, which is why this is named rather than written inline at its one call site.
    `git grep --extended-regexp` compiles the pattern with whatever `regcomp` the platform provides:
    glibc's on Linux, which accepts the GNU extensions, and the system one on macOS, which does not.
    Git adds Apple's `REG_ENHANCED` - the flag that would make `\\b` a word boundary there - only to
    patterns compiled WITHOUT `REG_EXTENDED` (`compat/regcomp_enhanced.c`), so an extended pattern
    never gets it, and `re_format(7)` reads a backslash before an ordinary character as that character.
    `Foo\\b` therefore searched for `Foob`: on macOS nothing was ever found, and every contract was
    reported as "no candidate built what is deployed" - a search that never looked, reported as one
    that found nothing.

    So the boundary is spelled the way both engines read alike: the name is not followed by another
    identifier character, or the line ends there - which a declaration whose brace is on the next line
    does."""
    return rf"^[[:space:]]*(abstract[[:space:]]+)?contract[[:space:]]+{re.escape(contract_type)}([^[:alnum:]_]|$)"


def source_at(
    repo_root: Path, commit: str, contract_type: str, recorded_path: str | None = None
) -> tuple[str, str] | None:
    """The file defining this contract at `commit` and the name it goes by THERE, or None.

    Two identities, because neither survives everything on its own:

    - The NAME survives a MOVE, which is the common case: `v3-oracles.json` records
      `src/Aggregator_…` where the tree later held `src/mainnet/Aggregator_…`, and building the
      recorded path at an older commit gave "No source files found" forty times. So the name is tried
      first, against that commit's own tree.
    - The recorded PATH, followed through git's rename detection, survives a RENAME - which the name
      cannot, by definition. The megaeth aggregators were `Aggregator_USDMY_*` when they were deployed
      and the token was renamed to USDM afterwards, so the manifest records a name that did not exist
      at the deploy: twelve contracts, fifty builds each, and not one comparison made.

    The name is tried FIRST because the path is the weaker fact - it is the path at deploy time, not
    at the candidate commit, and a moved file would otherwise be looked for where it no longer is.

    Returning the name AS DECLARED THERE is what makes the rename usable: the artefact must then be
    located by the name the build actually produced, not the one the manifest remembers.

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
            declaration_of(contract_type),
            commit,
            "--",
            "*.sol",
        ],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    declaring = [line.split(":", 1)[1] for line in found.stdout.splitlines() if ":" in line]
    if len(declaring) != 1:
        named = [p for p in declaring if p.rsplit("/", 1)[-1] == f"{contract_type}.sol"]
        declaring = named if len(named) == 1 else declaring
    if len(declaring) == 1:
        return declaring[0], contract_type
    if not recorded_path:
        return None
    was = _path_at(repo_root, commit, recorded_path)
    if was is None:
        return None
    declared = declared_in(repo_root, commit, was)
    return (was, declared) if declared else None


def submodule_commits(repo_root: Path, commit: str) -> dict[str, str]:
    """Every submodule the tree at `commit` records: path from this repository's root, to its commit.

    Read from the TREE, not from `.gitmodules`: the gitlink is what a checkout of this commit would
    place, where `.gitmodules` only says where to fetch it from. Recursive, because the closure reaches
    nested submodules - the OpenZeppelin contracts live inside contracts-upgradeable - and a blob in
    one resolves only against the commit its own parent records.

    A submodule that is not checked out here is still recorded, because the parent's tree says so, but
    cannot be descended into. That is the same trade `export_tree` makes: it may hold nothing the
    build needs, and `source_blobs` raises if it does.
    """
    found: dict[str, str] = {}

    def walk(parent: Path, parent_commit: str, prefix: str) -> None:
        listing = subprocess.run(["git", "ls-tree", "-r", parent_commit], cwd=parent, capture_output=True, text=True)
        for line in listing.stdout.splitlines():
            fields = line.split(maxsplit=3)
            if len(fields) < 4 or fields[1] != "commit":
                continue
            gitlink, path = fields[2], fields[3]
            found[f"{prefix}{path}"] = gitlink
            if (parent / path).is_dir():
                walk(parent / path, gitlink, f"{prefix}{path}/")

    walk(repo_root, commit, "")
    return found


def source_blobs(repo_root: Path, commit: str, paths: Iterable[str]) -> dict[str, str]:
    """Each path's git blob id at `commit` — the identity of the exact bytes a build read.

    A path inside a submodule is read against the commit the superproject RECORDS for that submodule,
    never the submodule's tip: otherwise the record would say what the dependency looks like today
    rather than what was built, and would change meaning every time the dependency moved.

    A path the commit does not have raises, because a record that cannot name every source is a record
    that cannot be rebuilt, and a missing one would leave a hole nothing else reports.
    """
    submodules = submodule_commits(repo_root, commit)
    found: dict[str, str] = {}
    for path in paths:
        # The longest match, so a file in a nested submodule is read against the nested gitlink rather
        # than its parent's.
        prefix = max((p for p in submodules if path.startswith(f"{p}/")), key=len, default=None)
        if prefix is None:
            holder, holder_commit, inside = repo_root, commit, path
        else:
            holder, holder_commit, inside = repo_root / prefix, submodules[prefix], path[len(prefix) + 1 :]
        shown = subprocess.run(
            ["git", "rev-parse", f"{holder_commit}:{inside}"], cwd=holder, capture_output=True, text=True
        )
        if shown.returncode != 0:
            raise FileNotFoundError(f"{path} is not in the tree at {commit[:10]}")
        found[path] = shown.stdout.strip()
    return found


def export_commit(source_repo: Path, tree: str, into: Path) -> None:
    """`tree`'s files, read from `source_repo`'s own object store, written into `into`.

    ONE repository's files: a gitlink is not followed, so a caller that wants the dependencies too
    asks for each of them. `export_tree` is that caller for the whole closure; `verify-audit` is one
    that wants only the dependencies its remappings can reach.

    Local, and that is what makes it usable against work in progress: the objects come from the
    checkout in hand, so a dependency sitting at an unpushed commit exports as readily as any other,
    where a clone would have to ask a remote that has never heard of it.

    Raises `subprocess.CalledProcessError` when git cannot produce the archive - most often because
    the object store does not hold `tree`."""
    done = subprocess.run(["git", "archive", "--format=tar", tree], cwd=source_repo, capture_output=True, check=True)
    into.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(done.stdout)) as archive:
        archive.extractall(into, filter="tar")


def export_tree(repo_root: Path, commit: str, at: Path) -> list[str]:
    """`commit`'s FILES at `at`, with every submodule at its recorded gitlink. Returns failures.

    Files, with no `.git` anywhere under `at`, and that is the whole point rather than an economy.
    A scratch made of linked worktrees shares the real repository's `.git/modules`, and `forge build`
    run in it settles the project's dependencies first: finding one it judges missing, it installs
    recursively, and that install re-points every SHARED gitdir's `core.worktree` at the scratch.
    The scratch is then deleted, leaving every dependency of the real checkout unreadable
    (`fatal: cannot chdir`). Measured both ways: forge installs nothing when there is no repository
    to install into, and the build fails instead with the file it could not resolve.

    Removing git from the scratch is also what makes this function's own promise keepable. Nothing
    here can now alter the repository it reads from, so there is no cleanup to get right and no
    worktree administration to leak - deleting the directory is the whole of it.

    Recursive, because the closure reaches nested submodules - the OpenZeppelin contracts live inside
    contracts-upgradeable, and a build without them does not fail cleanly, it fails as an unresolved
    import a long way from the cause.

    A submodule that cannot be exported is REPORTED rather than fatal: it may not be in the closure at
    all (`solidity-stringutils` was not, in the real recovery), and a build that needs it fails loudly
    naming the file, which is actionable. Guessing which are needed and placing too few is the failure
    that is silent."""
    failures: list[str] = []

    def export(parent_repo: Path, parent_commit: str, parent_at: Path, prefix: str) -> None:
        listing = subprocess.run(
            ["git", "ls-tree", parent_commit, "lib/"], cwd=parent_repo, capture_output=True, text=True
        )
        for line in listing.stdout.splitlines():
            fields = line.split()
            if len(fields) < 4 or fields[1] != "commit":
                continue
            gitlink, path = fields[2], fields[3]
            # A submodule the parent records but that is not checked out HERE has no object store to
            # read the recorded commit from. Reported rather than raised: it may not be in the closure
            # at all, and the build says so loudly if it is.
            if not (parent_repo / path).is_dir():
                failures.append(f"{prefix}{path}@{gitlink[:10]} (not checked out)")
                continue
            try:
                export_commit(parent_repo / path, gitlink, parent_at / path)
            except subprocess.CalledProcessError:
                # The one failure expected here: the checkout exists but its object store does not
                # hold the commit the parent records, which is the same "cannot be exported" answer.
                failures.append(f"{prefix}{path}@{gitlink[:10]}")
                continue
            export(parent_repo / path, gitlink, parent_at / path, f"{prefix}{path}/")

    export_commit(repo_root, commit, at)
    export(repo_root, commit, at, "")
    return failures


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


def differences(onchain: bytes, produced: bytes, references: dict, address: str) -> tuple[list[str], list[str]]:
    """Every way the deployed code differs from the code its constructor produced, split into the ones
    the deployment explains and the ones it does not. Empty `unexplained` is the verdict.

    This replaces masking as the thing that DECIDES. Masking makes a comparison possible but weakens
    what it proves: a match becomes a match *modulo the immutables*, so two sources differing only in a
    value that becomes an immutable - two aggregators with different Chainlink feeds - are
    indistinguishable, and "the only candidate that matched" is not evidence when the thing that would
    have told them apart was excluded before looking.

    They need not be excluded. These constructors take no arguments -
    `constructor() Aggregator_PAXG_USD(PAXG_USD.FEED, PAXG_USD.HEARTBEAT, 1, false) {}` - so every
    immutable is determined by the source, and executing the creation code reproduces it. Measured on
    `Aggregator_stETH_USD_mainnet`: 3356 bytes constructed against 3356 deployed, every differing byte
    inside an immutable region.

    ONE immutable genuinely cannot be reproduced: a contract's own address, because the construction
    runs somewhere else (OpenZeppelin's UUPS `__self`). That is recognised by its VALUE - the deployed
    slot holds the deployed address - not by excluding a class of regions, so an immutable that merely
    happens to be an address is not waved through.

    Everything else is unexplained, and unexplained means the source is not what was deployed. Each is
    named with both values, because a human deciding whether a baseline is true needs to see them."""
    if len(onchain) != len(produced):
        return [], [f"length: {len(onchain)} deployed, {len(produced)} constructed"]

    wanted = address.lower().removeprefix("0x")
    explained: list[str] = []
    unexplained: list[str] = []
    covered: set[int] = set()
    for regions in references.values():
        for region in regions:
            start, stop = region["start"], region["start"] + region["length"]
            covered.update(range(start, stop))
            here, there = onchain[start:stop], produced[start:stop]
            if here == there:
                continue
            padding, tail = here[:-20], here[-20:]
            if tail.hex() == wanted and not any(padding):
                explained.append(f"immutable at {start}: the contract's own address")
            else:
                unexplained.append(f"immutable at {start}: deployed {here.hex()}, constructed {there.hex()}")

    outside = [i for i, (a, b) in enumerate(zip(onchain, produced)) if a != b and i not in covered]
    if outside:
        unexplained.append(f"{len(outside)} byte(s) differ outside every immutable region, first at {outside[0]}")
    return explained, unexplained


def matches(onchain: bytes, artefact: dict) -> tuple[bool, list[str]]:
    """A SCREEN, not a verdict: could this artefact have built the deployed code, ignoring immutables?

    It exists to decide whether constructing is worth an RPC call. `differences` is what decides
    whether a baseline is true, and it needs the constructor run against the chain; running that for
    every candidate build would be one call per (contract, build) where this is free. So: screen here,
    prove there.

    Whether the deployed runtime code is what this artefact builds, and the immutables read off it.

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
