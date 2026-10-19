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
import os
import subprocess
import tomllib
from collections.abc import Iterable
from dataclasses import asdict, dataclass, fields, replace
from datetime import datetime
from pathlib import Path

from deployment_recovery import checkouts_by_repository, checkouts_of, declared_in, holds, placement
from deployment_records import Entry, Problem, normalise, read_records

SCHEMA_VERSION = 1
RECORD = "deployed.json"
# The person's words for each deployment tag, beside the record they describe: one line per tag, saying
# what was deployed. Written by hand, never generated: `--write` appends an entry for a tag that has none,
# and removes an earlier entry only once its words are carried to the new name (`replaced_labels`).
LABELS = "deployed-labels.toml"
_LABELS_HEADER = (
    "# One line per deployment tag, saying what was deployed. Write the labels here, never on the tag:\n"
    "# verify-audit --write puts each one at the head of its tag's message. For a tag with no line, it adds\n"
    "# one with the words of the same deploy's line under an earlier name, and removes that earlier line.\n"
    "# With no such line, or several that differ, the new one is empty, for you to fill in.\n"
)


class UnreadableLabels(Exception):
    """The labels file is not valid TOML. Its message is what was found."""


class UnknownSchema(Exception):
    """The record was written by a version this does not understand.

    Raised rather than tolerated: every manifest in the fleet carries `schemaVersion: 1` and nothing
    reads it, which makes the field decoration. A version that is asserted is what makes changing the
    schema later safe, because an old reader stops instead of misreading."""


class Conflict(Exception):
    """A baseline already exists for this address, saying something different. Never resolved here -
    which of the two is true is a question about the chain, not about a file."""


class UnreadableRecord(Exception):
    """The record is not valid JSON. Its message is what was found, and when the file holds the markers a
    conflicting merge leaves, the repair.

    The record is generated, so the repair is never an edit. Two clones that recorded different contracts
    conflict as whole files, and either side is a record the generator wrote: keep one, and `--write`
    records from the state files whatever that side lacks."""

    def __init__(self, broken: json.JSONDecodeError, text: str):
        markers = [
            number
            for number, line in enumerate(text.splitlines(), 1)
            if line.startswith(("<<<<<<< ", "||||||| ", ">>>>>>> ")) or line == "======="
        ]
        lines = [f"{RECORD} is not valid JSON: {broken.msg} at line {broken.lineno}, column {broken.colno}"]
        if markers:
            lines += [
                f"it holds merge-conflict markers at line(s) {', '.join(str(number) for number in markers)}",
                f"keep one side whole: git checkout --ours {RECORD}, or git checkout --theirs {RECORD}",
                "then run verify-audit --write, which records from the state files what that side lacks",
            ]
        super().__init__("\n".join(lines))


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
    # Each external library this contract was LINKED against, `<file>:<Library>` to its address, read
    # from the deployed runtime code at the offsets the build declared. Recorded rather than folded
    # into `creationBytecodeKeccak256` because an address is decided when the build is linked, not by
    # the source - the same reason that hash already excludes constructor arguments. Empty for a
    # contract that links nothing, which is most of them.
    libraries: dict[str, str]
    # What the constructor was given, ABI-encoded, as the deployment appended it to the creation
    # bytecode. Empty for a constructor that takes nothing.
    #
    # The ONLY deployment input here that the deployed contract does not carry: an immutable and a
    # library address are both readable from the runtime code, which is why neither is recorded and
    # both can be re-derived whenever they are wanted. An argument lives only in the creation
    # payload, which only the transaction that created the contract carries - so a baseline that does
    # not name it cannot be re-proved without reading the chain again, and the re-prove is deliberately
    # offline.
    constructorArguments: str


def key(chain_id: int, address: str) -> str:
    """The identity of a deployed contract, as one string.

    The chain is its ID, not a name: eight spellings covered four chains across these manifests
    (`Mainnet`/`mainnet`, `MegaETH`/`megaeth`), and a name is a label anyone can write differently. The
    id also caught a manifest recording `chainId: 0` for MegaETH where four others say 4326 - a defect
    no amount of name-matching would have seen.

    The address is lowercased because manifests checksum it, and two spellings of one address would
    otherwise become two baselines for one artefact."""
    return f"{chain_id}/{address.lower()}"


# Every tag the record derives starts with this, which is what lets one fetch take origin's version of
# exactly these tags and of no other.
DEPLOY_TAGS = "deploy/"

# The one tag fetch, used by `verify-audit --push` and by `yarn dep`: every tag origin has, with origin's
# version of a deployment tag replacing the one held here. A plain `--tags` fetch refuses to replace a tag
# a clone already holds ("would clobber existing tag"), so a tag corrected in one clone would stop every
# other clone's fetch instead of reaching it. Only the deployment tags are forced: the record derives their
# names, so origin's copy is the shared one. Any other tag is its owner's, and a clash there is refused.
#
# TAGS ONLY. A refspec given on the command line replaces the remote's configured ones, so this leaves every
# `refs/remotes/origin/…` branch where it was. Where the branches are wanted too, `FETCH_BRANCHES` runs
# first: the two together fetch what a plain `git fetch --tags` did.
FETCH_TAGS = (
    "fetch",
    "--quiet",
    "--tags",
    "--no-recurse-submodules",
    "origin",
    f"+refs/tags/{DEPLOY_TAGS}*:refs/tags/{DEPLOY_TAGS}*",
)

# Origin's branches, by the remote's configured refspecs. The dependency alone: git's fetch otherwise follows
# any nested submodule that happens to be checked out and fails on a nested pin no remote holds.
FETCH_BRANCHES = ("fetch", "--quiet", "--no-recurse-submodules", "origin")


def _tag_prefix(state_file: str) -> str:
    """What every tag a state file derives starts with: `deploy/<chain>/<file>`.

    DERIVED, not agreed. A state file lives at `deployments/<chain>/<file>.json`, so the prefix is that
    path with the directory and the suffix removed - which makes "does this tag match the record"
    string equality rather than a naming convention someone has to keep, and puts the chain in the name
    for free."""
    return f"{DEPLOY_TAGS}{state_file.removeprefix('deployments/').removesuffix('.json')}"


def reached_by(repo_root: Path, commit: str) -> list[str]:
    """Every ref that reaches `commit` - branches first, then tags.

    "Push that branch" without saying WHICH is a remedy the reader has to go and derive, and the answer
    was already in hand: `commit_reach` runs these very queries and keeps only whether the output was
    empty. Every one is named rather than the first, because naming one of several would send someone
    to push a branch they did not mean."""
    return _contains(repo_root, "branch", commit) + _contains(repo_root, "tag", commit)


# The last line of every annotated tag the tool makes, as it has been since it first annotated them. A
# stale tag ending with it is the tool's own, so it holds nothing the record cannot make again.
_TOOL_LINE = "recorded in deployed.json; this tag is what keeps the commit reachable"


def _seconds(timestamp: str) -> int:
    """An ISO 8601 timestamp from the record, as Unix seconds."""
    return int(datetime.fromisoformat(timestamp).timestamp())


def _deploy_span(built: list[Baseline]) -> tuple[Baseline, Baseline]:
    """The first and the last contract of a tag's deploy, by block."""
    by_block = sorted(built, key=lambda baseline: (baseline.deployBlock, baseline.deployTimestamp))
    return by_block[0], by_block[-1]


def tag_message(built: list[Baseline], label: str) -> str:
    """What a deployment tag says about `built`, the contracts it covers: its label - the person's line on
    what was deployed, which is what `git tag -n` shows - then the tool's lines.

    The tool's lines say when the deploy happened - its first and last block, at the chain's own times -
    and where the commit falls against it: at or before the first contract is the search's first pass;
    after the last, its second, where the deploy ran from changes committed only afterwards. They name the
    COMMIT, not the contracts: many contracts share one - twenty-two of harbor's - and deployed.json is
    where which-contracts is answered. Timestamps are in full ISO 8601, as the record holds them, because a
    message may hold the colons a ref name cannot."""
    first, last = _deploy_span(built)
    if first.deployBlock == last.deployBlock:
        deployed = f"deployed in block {first.deployBlock} at {first.deployTimestamp}"
    else:
        deployed = (
            f"deployed in blocks {first.deployBlock} to {last.deployBlock},"
            f" {first.deployTimestamp} to {last.deployTimestamp}"
        )
    committed = built[0].commitTimestamp
    if _seconds(committed) <= _seconds(first.deployTimestamp):
        side = "before the deploy"
    elif _seconds(committed) > _seconds(last.deployTimestamp):
        side = "after the deploy, which ran from changes not yet committed"
    else:
        side = "during the deploy"
    return f"{label}\n\n{deployed}\nsource of deployed code, committed {committed}, {side}\n{_TOOL_LINE}"


def tag_date(built: list[Baseline]) -> str:
    """The date a deployment tag carries: its deploy's first block's time. So the tag says when the deploy
    ran, and `git tag --sort=creatordate` lists deployment tags in deploy order, as their names sort."""
    return _deploy_span(built)[0].deployTimestamp


def derived_tags(baselines: Iterable[Baseline]) -> dict[str, list[Baseline]]:
    """Each tag the record derives, sorted by name, to every baseline it covers. They share one commit,
    and the deploy the tag describes spans their blocks.

    A tag is one state file's contracts from one commit, named `<prefix>@<time>`: the state file's
    `_tag_prefix`, and its deploy's first block time (`tag_date`) with each `:` as `-`, since a ref name
    cannot hold a colon. So the names sort in deploy order, and a reader sees when each deploy ran.

    One per state file, because a commit serves several: 25 such pairs across the aggregators' twelve
    recorded commits, since 44 of their addresses are described by two manifests.

    When two commits' deploys into one state file begin in the same second, each name gains `@` and its
    commit's first 10 characters, so neither is chosen over the other.

    `@` rather than `/`: `refs/tags/deploy/mainnet/v4-oracles` as a file blocks any directory of that
    name, so a further path segment cannot be created beside it. `@` keeps the time inside the last
    segment, where it can."""
    groups: dict[tuple[str, str], list[Baseline]] = {}
    for baseline in baselines:
        for state_file in baseline.stateFiles:
            groups.setdefault((_tag_prefix(state_file), baseline.commit), []).append(baseline)
    named: dict[str, list[tuple[str, list[Baseline]]]] = {}
    for (prefix, commit), built in groups.items():
        named.setdefault(f"{prefix}@{tag_date(built).replace(':', '-')}", []).append((commit, built))
    tags: dict[str, list[Baseline]] = {}
    for name, claims in named.items():
        if len(claims) == 1:
            tags[name] = claims[0][1]
        else:
            for commit, built in claims:
                tags[f"{name}@{commit[:10]}"] = built
    return dict(sorted(tags.items()))


def _prefix_of(name: str, prefixes: Iterable[str]) -> str | None:
    """The state file prefix `name` is a tag under, `<prefix>@…`, or None."""
    return next((prefix for prefix in prefixes if name.startswith(f"{prefix}@")), None)


def _stale_names(names: Iterable[str], record: list[Baseline]) -> list[str]:
    """Those of `names` the record no longer derives: under the prefix of a state file the record holds
    contracts for, but not a name it derives."""
    prefixes = {_tag_prefix(state_file) for baseline in record for state_file in baseline.stateFiles}
    derived = derived_tags(record)
    return sorted(name for name in names if name not in derived and _prefix_of(name, prefixes) is not None)


def stale_tags(repo_root: Path, baselines: Iterable[Baseline]) -> list[str]:
    """The deployment tags held here that the record no longer derives: named under a state file the
    record holds contracts for, but not a name it derives. A tag's name moves when the record gains an
    earlier contract under it, and every tag named by the commit alone, as they once were, no longer
    matches. Those the tool replaces (`replaced_tags`) it deletes; any other is the person's to delete.

    A tag under no such state file is left alone, so a hand-made `deploy/harbor-1.0.1` is not one."""
    return _stale_names(_held_tags(repo_root), list(baselines))


def replaced_tags(repo_root: Path, baselines: Iterable[Baseline], tags: dict[str, Tag] | None = None) -> dict[str, str]:
    """Each stale tag of `tags` - this clone's when not given - that the tool may delete, to the tag the
    record derives in its place.

    A REPLACED tag is on the same commit as the tag the record derives under its state file's prefix, and
    holds nothing the record cannot make again: it is lightweight, or annotated with the tool's last line.
    The commit keeps its tag through the replacement, so deleting it loses nothing. An annotated tag whose
    object is not here cannot be read, so it is not counted; nor is any other stale tag, which is the
    person's."""
    record = list(baselines)
    tags = _held_tags(repo_root) if tags is None else tags
    prefixes = {_tag_prefix(state_file) for baseline in record for state_file in baseline.stateFiles}
    replacing = {(_prefix_of(tag, prefixes), built[0].commit): tag for tag, built in derived_tags(record).items()}
    replaced: dict[str, str] = {}
    for name in _stale_names(tags, record):
        found = tags[name]
        replacement = replacing.get((_prefix_of(name, prefixes), found.commit))
        if replacement is None:
            continue
        if found.object != found.commit:
            shown = subprocess.run(
                ["git", "cat-file", "tag", found.object], cwd=repo_root, capture_output=True, text=True
            )
            if shown.returncode != 0 or shown.stdout.rstrip().splitlines()[-1:] != [_TOOL_LINE]:
                continue
        replaced[name] = replacement
    return replaced


def stale_repair(tags: list[str], on_origin: list[str] | None) -> list[str]:
    """The person's deletion of `tags`, stale tags the tool does not replace, as lines to print. Origin's
    deletion comes first: while origin holds a tag, the next fetch brings it back. `on_origin` names those
    origin holds; None when this run did not ask, and then origin's deletion is given for all, where it
    holds them."""
    there = tags if on_origin is None else on_origin
    if not there:
        return ["Deleting them is yours. To delete them here:", f"  git tag -d {' '.join(tags)}"]
    where = ", where it holds them" if on_origin is None else ""
    return [
        f"Deleting them is yours. First on origin{where}: while origin holds a tag, the next fetch brings it back"
        " here.",
        f"  git push origin --delete {' '.join(f'refs/tags/{tag}' for tag in there)}",
        "Then here:",
        f"  git tag -d {' '.join(tags)}",
    ]


def read_labels(repo_root: Path) -> dict[str, object]:
    """Each entry the labels file holds, by tag name, as written. No file holds none."""
    path = repo_root / LABELS
    if not path.is_file():
        return {}
    try:
        return tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as broken:
        raise UnreadableLabels(f"{LABELS} is not valid TOML: {broken}") from broken


def label_errors(labels: dict[str, object], derived: Iterable[str]) -> list[tuple[str, str]]:
    """(tag or entry, what is wrong) for each tag the record derives whose label is missing or cannot serve
    as one, and for each entry naming no tag the record derives - a misspelt or stale entry, whose text
    would otherwise go nowhere. A label is one line of words, since the first line is all `git tag -n`
    shows.

    Every derived tag needs one, whatever other tags its commit has: a release tag keeps the commit, but
    is not dated as the deploy and does not say what was deployed."""
    errors: list[tuple[str, str]] = []
    known = list(derived)
    for tag in known:
        label = labels.get(tag)
        if tag not in labels:
            errors.append((tag, f"no label in {LABELS}"))
        elif not isinstance(label, str):
            errors.append((tag, "its label is not text"))
        elif not label.strip():
            errors.append((tag, "its label is empty"))
        elif "\n" in label or "\r" in label:
            errors.append((tag, "its label holds a line break, and a label is one line"))
    errors += [(entry, "names no tag the record derives") for entry in labels if entry not in known]
    return errors


def append_labels(
    repo_root: Path, tags: Iterable[str], labels: dict[str, object], derived: dict[str, list[Baseline]]
) -> dict[str, str]:
    """Add an entry to the labels file for each of `tags`, creating the file with a header when absent, and
    return what each entry says. Only ever appends: what the person wrote, comments and layout included,
    stays.

    An entry carries the words `labels` holds for the same deploy under a name the record no longer
    derives (`_earlier_entries`), so a renamed tag keeps its label. The earlier entry stays until `--write`
    removes it (`replaced_labels`). With no such words, or with several that differ, the entry is empty, for
    the person to fill in."""
    held = _held_tags(repo_root)
    added: dict[str, str] = {}
    for tag in tags:
        earlier = {
            text
            for entry, text in _earlier_entries(tag, derived, labels, held).items()
            if isinstance(text, str) and text.strip()
        }
        added[tag] = earlier.pop() if len(earlier) == 1 else ""
    path = repo_root / LABELS
    existing = path.read_text() if path.is_file() else ""
    lead = _LABELS_HEADER if not path.is_file() else ("" if existing.endswith("\n") or not existing else "\n")
    # Each key and value as a TOML basic string. TOML's escapes include all of JSON's, and of the characters
    # TOML requires escaped, JSON leaves only DEL as it is.
    written = "".join(
        json.dumps(tag) + " = " + json.dumps(text, ensure_ascii=False).replace("\x7f", "\\u007f") + "\n"
        for tag, text in added.items()
    )
    with path.open("a") as file:
        file.write(lead + written)
    return added


def _earlier_entries(
    tag: str, derived: dict[str, list[Baseline]], labels: dict[str, object], held: dict[str, Tag]
) -> dict[str, object]:
    """The entries of `labels` for `tag`'s deploy under a name the record no longer derives: same state
    file, and either its name by commit alone, `<prefix>@<the commit's first 10 characters>`, or a tag held
    here on that commit."""
    built = derived[tag]
    commit = built[0].commit
    prefix = _prefix_of(tag, map(_tag_prefix, built[0].stateFiles))
    return {
        entry: text
        for entry, text in labels.items()
        if entry not in derived
        and entry.startswith(f"{prefix}@")
        and (entry == f"{prefix}@{commit[:10]}" or (entry in held and held[entry].commit == commit))
    }


def replaced_labels(repo_root: Path, labels: dict[str, object], derived: dict[str, list[Baseline]]) -> dict[str, str]:
    """The entries `--write` removes: each earlier entry of a deploy (`_earlier_entries`) whose words are
    exactly those of the deploy's own entry. They were carried to the new name, so nothing is lost."""
    held = _held_tags(repo_root)
    return {
        entry: text
        for tag in derived
        if isinstance(labels.get(tag), str)
        for entry, text in _earlier_entries(tag, derived, labels, held).items()
        if text == labels[tag]
    }


def remove_labels(repo_root: Path, entries: dict[str, str]) -> list[str]:
    """Remove from the labels file each line holding exactly one of `entries`, name and words both, and
    return their names. Each line is read on its own, so every other line stays byte for byte: comments,
    layout and the person's other entries."""
    path = repo_root / LABELS
    if not entries or not path.is_file():
        return []
    kept: list[str] = []
    removed: list[str] = []
    for line in path.read_text().splitlines(keepends=True):
        try:
            parsed = tomllib.loads(line)
        except tomllib.TOMLDecodeError:
            # Part of a value written across lines, which is no single entry to remove.
            parsed = {}
        if len(parsed) == 1 and next(iter(parsed.items())) in entries.items():
            removed.append(next(iter(parsed)))
        else:
            kept.append(line)
    if removed:
        path.write_text("".join(kept))
    return removed


@dataclass(frozen=True)
class Tag:
    """A tag as one repository holds it."""

    object: str  # what the ref names: a tag object when annotated, the commit itself when lightweight
    commit: str  # the commit it resolves to


class OriginUnanswered(Exception):
    """Origin could not be asked for its tags. Its message is git's words, which say where it looked."""


def origin_tags(repo_root: Path) -> dict[str, Tag]:
    """Every tag origin has, by name. Raises `OriginUnanswered` when origin cannot be asked.

    Git keeps a copy of each remote BRANCH (`refs/remotes/origin/…`) but none of the remote's tags: a
    fetched tag and one made here are the same thing in `refs/tags/`. So what origin holds can only be
    settled by asking it. An annotated tag is listed twice: the tag object, then a `^{}` line with the
    commit it resolves to."""
    listed = subprocess.run(["git", "ls-remote", "--tags", "origin"], cwd=repo_root, capture_output=True, text=True)
    if listed.returncode != 0:
        said = (listed.stderr or listed.stdout).strip()
        raise OriginUnanswered(said or f"git ls-remote exited {listed.returncode}")
    objects: dict[str, str] = {}
    commits: dict[str, str] = {}
    for line in listed.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            commits[name.removesuffix("^{}")] = sha
        elif name:
            objects[name] = sha
    return {name: Tag(found, commits.get(name, found)) for name, found in objects.items()}


def _held_tags(repo_root: Path) -> dict[str, Tag]:
    """The deployment tags this clone holds, by name."""
    listed = subprocess.run(
        [
            "git",
            "for-each-ref",
            "--format=%(refname:strip=2) %(objectname) %(objecttype) %(*objectname)",
            f"refs/tags/{DEPLOY_TAGS}",
        ],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    held: dict[str, Tag] = {}
    for line in listed.stdout.splitlines():
        name, found, kind, peeled = (line.split(" ") + [""])[:4]
        held[name] = Tag(found, peeled if kind == "tag" else found)
    return held


def _faults(repo_root: Path, tag: str, held: Tag, built: list[Baseline], label: str) -> list[str]:
    """How the tag held here differs from what the record derives for it from `built`, the contracts it
    covers, and its `label`: empty when it does not.

    The date is compared, because it says when the deploy ran (`tag_date`). The tagger is not, so one
    another clone made is as good as one made here."""
    faults: list[str] = []
    if held.commit != built[0].commit:
        faults.append(f"it was on {held.commit[:10]}")
    if held.object == held.commit:
        faults.append("it was lightweight")
        return faults
    dated, _, said = subprocess.run(
        ["git", "for-each-ref", "--format=%(taggerdate:unix)%00%(contents)", f"refs/tags/{tag}"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    ).stdout.partition("\0")
    if said.strip() != tag_message(built, label):
        faults.append("its message was not the derived one")
    if dated != str(_seconds(tag_date(built))):
        faults.append(f"its date was not its deploy's, {tag_date(built)}")
    return faults


@dataclass(frozen=True)
class Made:
    """What `make_tags` did here."""

    created: list[str]
    corrected: list[tuple[str, str]]  # (tag, how it differed from what the record derives)
    unmade: list[tuple[str, str]]  # (tag, git's words)


def make_tags(repo_root: Path, baselines: Iterable[Baseline], labels: dict[str, str]) -> Made:
    """Make, here, each tag in `labels` that this clone lacks, and correct each one it holds that is not
    what the record derives. `push_tags` sends them; this touches nothing outside the clone.

    `labels` holds the derived tags whose labels are sound (`label_errors`), so a tag whose label is in
    error is left as it is: made, it would only be wrong.

    A tag is correct when it is annotated, on the recorded commit, carries `tag_message`, and is dated as
    its deploy (`tag_date`).

    Returns what it could not make as well, because `git tag` fails for reasons that matter: the commit
    absent from a shallow checkout, refs that are read-only. Swallowing those would leave the check red
    with nothing saying why."""
    held = _held_tags(repo_root)
    created: list[str] = []
    corrected: list[tuple[str, str]] = []
    unmade: list[tuple[str, str]] = []
    for tag, built in derived_tags(baselines).items():
        if tag not in labels:
            continue
        here = held.get(tag)
        faults = [] if here is None else _faults(repo_root, tag, here, built, labels[tag])
        if here is not None and not faults:
            continue
        # ANNOTATED. A lightweight tag has no message, and `git tag -n` then prints the COMMIT's subject
        # line instead - which describes whatever that commit was about and says nothing about why the
        # tag exists, while looking exactly like an annotation that does. DATED as its deploy's first
        # block (`tag_date`), through the committer date git gives a tag. `-f` writes over a tag that is
        # not correct, and creating one needs no other path.
        done = subprocess.run(
            ["git", "tag", "-a", "-f", tag, "-m", tag_message(built, labels[tag]), built[0].commit],
            cwd=repo_root,
            capture_output=True,
            text=True,
            env={**os.environ, "GIT_COMMITTER_DATE": tag_date(built)},
        )
        if done.returncode != 0:
            said = (done.stderr or done.stdout or "").strip()
            unmade.append((tag, said.splitlines()[-1] if said else f"git tag exited {done.returncode}"))
        elif here is None:
            created.append(tag)
        else:
            corrected.append((tag, ", ".join(faults)))
    return Made(created, corrected, unmade)


def _origin_holds(repo_root: Path, commit: str, origin: dict[str, Tag]) -> bool:
    """Whether origin already holds `commit`: on one of its branches, as this clone last fetched them, or
    under a tag origin has."""
    on_a_branch = subprocess.run(
        ["git", "for-each-ref", "--count=1", "--contains", commit, "refs/remotes/origin"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    if on_a_branch.stdout.strip():
        return True
    tagged = subprocess.run(
        ["git", "for-each-ref", "--format=%(refname:strip=2) %(objectname)", "--contains", commit, "refs/tags"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    for line in tagged.stdout.splitlines():
        name, _, found = line.partition(" ")
        if name in origin and origin[name].object == found:
            return True
    return False


def _leased_push(repo_root: Path, leases: dict[str, str], refspecs: list[str]) -> dict[str, tuple[str, str]]:
    """Push `refspecs` to origin, each tag leased on the object origin held when it was looked at - empty
    when it held none - and return each leased tag's (flag, summary) as git's porcelain gives them: `*` new,
    `+` forced, `-` deleted, anything else refused. So a push changes only the copy looked at, never one
    another clone put there since.

    One line per ref: `<flag>\\t<source>:<destination>\\t<summary>`, read by destination, which a deletion
    has alone. A push that failed before reaching any ref prints none, and then git's last line of complaint
    is the reason for every tag."""
    done = subprocess.run(
        [
            "git",
            "push",
            "--porcelain",
            "origin",
            *(f"--force-with-lease=refs/tags/{tag}:{lease}" for tag, lease in leases.items()),
            *refspecs,
        ],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    reported: dict[str, tuple[str, str]] = {}
    for line in done.stdout.splitlines():
        flag, _, rest = line.partition("\t")
        refs, _, summary = rest.partition("\t")
        destination = refs.partition(":")[2]
        if destination.startswith("refs/tags/"):
            reported[destination.removeprefix("refs/tags/")] = (flag, summary)
    complaint = (done.stderr.strip().splitlines() or [f"git push exited {done.returncode}"])[-1]
    return {tag: reported.get(tag, ("!", complaint)) for tag in leases}


@dataclass(frozen=True)
class Pushed:
    """What `push_tags` did on origin."""

    pushed: list[str]  # new on origin
    replaced: list[str]  # origin's copy replaced, by a forced push of that tag alone
    adopted: list[str]  # origin's copy changed while this push was made, and is correct: taken
    waiting: list[tuple[str, str, list[str]]]  # (tag, its commit, the branches here holding it)
    refused: list[tuple[str, str]]  # (tag, why)


def push_tags(repo_root: Path, baselines: Iterable[Baseline], origin: dict[str, Tag], labels: dict[str, str]) -> Pushed:
    """Push each tag in `labels` that origin lacks or holds differently. Only these tags are named, so a
    tag that has nothing to do with deployments never leaves this clone with them, and neither does one
    whose label is in error, which `make_tags` left uncorrected.

    A tag is pushed only when origin already holds its commit, on a branch or under a tag origin has.
    Pushing a tag carries its commit along, so otherwise this would publish work nobody pushed.

    Each push is leased on the copy `origin` says origin held: `--force-with-lease=<ref>:<that object>`,
    empty when it held none. So a push replaces only the copy that was looked at, and never one another
    clone changed in between. When a lease fails, origin is asked again. A tag that is now what the record
    derives is taken, since which clone made it makes no difference. Anything else is reported, and never
    forced over.

    Not atomic: a tag origin refuses does not hold back the others."""
    tags = derived_tags(baselines)
    held = _held_tags(repo_root)
    sending: list[tuple[str, str]] = []  # (tag, the lease: what origin held)
    waiting: list[tuple[str, str, list[str]]] = []
    for tag in unpublished_tags(repo_root, [baseline for built in tags.values() for baseline in built], origin):
        if tag not in labels:
            continue
        here, there = held[tag], origin.get(tag)
        if not _origin_holds(repo_root, here.commit, origin):
            waiting.append((tag, here.commit, _contains(repo_root, "branch", here.commit)))
            continue
        sending.append((tag, there.object if there is not None else ""))
    if not sending:
        return Pushed([], [], [], waiting, [])

    reported = _leased_push(repo_root, dict(sending), [f"refs/tags/{tag}" for tag, _ in sending])
    pushed: list[str] = []
    replaced: list[str] = []
    rejected: list[tuple[str, str, str]] = []  # (tag, lease, why)
    for tag, lease in sending:
        flag, summary = reported[tag]
        if flag == "*":
            pushed.append(tag)
        elif flag == "+":
            replaced.append(tag)
        else:
            rejected.append((tag, lease, summary))

    adopted: list[str] = []
    refused: list[tuple[str, str]] = []
    if rejected:
        fetched = subprocess.run(["git", *FETCH_TAGS], cwd=repo_root, capture_output=True, text=True)
        try:
            now: dict[str, Tag] | None = origin_tags(repo_root)
        except OriginUnanswered:
            # Asked again only to explain a rejection: unanswered, every rejected tag is reported as refused.
            now = None
        held = _held_tags(repo_root)
        for tag, lease, why in rejected:
            there = None if now is None else now.get(tag)
            changed = now is not None and (there.object if there is not None else "") != lease
            if not changed:
                refused.append((tag, why))
                continue
            here = held.get(tag)
            if fetched.returncode == 0 and here == there and not _faults(repo_root, tag, here, tags[tag], labels[tag]):
                adopted.append(tag)
                continue
            refused.append(
                (
                    tag,
                    "origin's copy changed while this run pushed it, and is not what the record derives. "
                    "Run verify-audit --push again",
                )
            )
    return Pushed(pushed, replaced, adopted, waiting, refused)


def unpublished_tags(repo_root: Path, baselines: Iterable[Baseline], origin: dict[str, Tag]) -> list[str]:
    """The deployment tags this clone holds that origin lacks or holds differently: what a push would
    send, or hold back for a commit origin lacks."""
    held = _held_tags(repo_root)
    return [
        tag
        for tag in derived_tags(baselines)
        if tag in held and (tag not in origin or origin[tag].object != held[tag].object)
    ]


@dataclass(frozen=True)
class Deleted:
    """What `delete_replaced_tags` did."""

    here: list[tuple[str, str]]  # (replaced tag, its replacement), deleted here
    on_origin: list[str]  # of those, the ones deleted on origin first
    refused: list[tuple[str, str]]  # (replaced tag, origin's reason): kept, here and there
    kept: list[str]  # replaced tags kept, as their replacement is not in place - here, or on origin


def delete_replaced_tags(
    repo_root: Path,
    baselines: Iterable[Baseline],
    in_place: set[str],
    origin: dict[str, Tag] | None = None,
    sent: Pushed | None = None,
) -> Deleted:
    """Delete each replaced tag held here (`replaced_tags`) once its replacement is in place. `in_place` is
    the tags the record derives that are correct here once `make_tags` has run.

    `--write` gives no `origin`: it reads only this clone, so it deletes a replaced tag here once its
    replacement is made, and `--push` deletes it on origin. `--push` gives origin as listed before it
    pushed, and what `push_tags` did. A replaced tag origin holds is deleted there only once origin holds
    the replacement as this clone does - pushed now, or there already - leased on the copy listed, and then
    here. One origin refuses to delete stays here as well, since the next fetch would bring it back."""
    replaced = replaced_tags(repo_root, baselines)
    held = _held_tags(repo_root)
    published = set() if sent is None else {*sent.pushed, *sent.replaced, *sent.adopted}
    ready: dict[str, str] = {}
    leases: dict[str, str] = {}
    kept: list[str] = []
    for tag, replacement in replaced.items():
        if replacement not in in_place:
            kept.append(tag)
            continue
        if origin is not None and tag in origin:
            if replacement not in published and (
                replacement not in origin or origin[replacement].object != held[replacement].object
            ):
                kept.append(tag)
                continue
            leases[tag] = origin[tag].object
        ready[tag] = replacement
    reported = _leased_push(repo_root, leases, [f":refs/tags/{tag}" for tag in leases]) if leases else {}
    refused = [(tag, summary) for tag, (flag, summary) in reported.items() if flag != "-"]
    for tag, _ in refused:
        del ready[tag]
    for tag in ready:
        subprocess.run(["git", "tag", "-d", tag], cwd=repo_root, capture_output=True, text=True, check=True)
    return Deleted(sorted(ready.items()), sorted(tag for tag in leases if tag in ready), refused, kept)


@dataclass(frozen=True)
class OriginComparison:
    """How origin's deployment tags stand against the record and this clone."""

    lacking: list[str]  # tags the record derives that origin does not hold
    differing: list[str]  # tags the record derives that origin holds as another object than this clone's
    stale: dict[str, str | None]  # names origin holds that the record no longer derives, to the replacement


def compare_with_origin(repo_root: Path, baselines: Iterable[Baseline], origin: dict[str, Tag]) -> OriginComparison:
    """Origin's deployment tags, as `origin_tags` listed them, against the record and this clone. A stale
    name maps to the tag replacing it when the tool may delete it (`replaced_tags`), and to None when
    deleting it is the person's."""
    record = list(baselines)
    replaced = replaced_tags(repo_root, record, origin)
    return OriginComparison(
        lacking=[tag for tag in derived_tags(record) if tag not in origin],
        differing=[tag for tag in unpublished_tags(repo_root, record, origin) if tag in origin],
        stale={name: replaced.get(name) for name in _stale_names(origin, record)},
    )


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
    text = path.read_text()
    try:
        document = json.loads(text)
    except json.JSONDecodeError as broken:
        raise UnreadableRecord(broken, text) from broken
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
    # (baseline, the inputs this clone cannot look at) - inside a submodule whose repository has no
    # checkout anywhere in the tree. Separate from missing because a partial checkout is not a defect,
    # and failing on it would fail every developer's build for a clone only CI makes.
    inputs_unchecked: list[tuple[Baseline, list[str]]]
    # Each tag the record derives that is not held here, to the baselines it covers. The tag keeps its
    # commit: a branch holding it is not preservation, since branches move, are force-pushed and are
    # deleted when work merges, where a tag does none of those. It also names the deploy - dated as it, and
    # saying what was deployed - so another tag on the same commit, such as a release, does not stand in.
    missing_tags: dict[str, list[Baseline]]
    # (baseline, what its source actually declares) where the two disagree, `None` when the source
    # declares no single contract. A deployment record is a record of a DEPLOYMENT, so its contract
    # name is the name at deploy time and the source at that commit declares exactly that. Twelve of
    # the aggregators' eighty-three disagree, every one a rewrite after a rename.
    misnamed: list[tuple[Baseline, str | None]]
    # (tag, how it differs) for each deployment tag held here that is not what the record derives - see
    # `make_tags` for what correct means. A tag on each recorded commit is not enough: a wrong one is dated
    # otherwise than its deploy, or says the wrong thing. Only tags whose labels are sound; one in error is
    # reported once, in `label_errors`.
    wrong_tags: list[tuple[str, str]]
    # (tag or entry, what is wrong) - see `label_errors`.
    label_errors: list[tuple[str, str]]
    # The deployment tags held here that the record no longer derives - see `stale_tags`.
    stale_tags: list[str]
    # Of those, each the tool deletes, to the tag replacing it - see `replaced_tags`.
    replaced_tags: dict[str, str]


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
    repo_root: Path, baselines: list[Baseline], placed: dict[str, dict[str, tuple[str, Path | None]]]
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
    `placed` gives, per baseline key, the submodules its sources live in as `placement` takes them.

    One `git cat-file` per holding repository, not per source: eighty-three baselines naming thirty-two
    sources each is two and a half thousand lookups, asked as about thirty."""
    unchecked_by: dict[int, list[str]] = {}
    by_holder: dict[Path, list[tuple[int, str, str, str]]] = {}
    for index, baseline in enumerate(baselines):
        submodules = placed[key(baseline.chainId, baseline.address)]
        for path, blob in sorted(baseline.sources.items()):
            _, holder, at, inside = placement(repo_root, baseline.commit, path, submodules)
            if holder is None:
                unchecked_by.setdefault(index, []).append(path)
                continue
            by_holder.setdefault(holder, []).append((index, path, f"{at}:{inside}", blob))
        for path, (gitlink, holder) in sorted(submodules.items()):
            if holder is None:
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
    # Only where the commit is present, for the reason `misnamed` gives below: a baseline whose commit
    # this repository has lost would report every one of its sources as missing too, sending the reader
    # after thirty-two files when the finding is one lost commit.
    present = [baselines[k] for k in sorted(baselines) if reaches[baselines[k].commit] != "absent"]
    # Where each present baseline's submodules are read, as `placement` takes them.
    #
    # Only a submodule some recorded source lives in. A baseline names thirty-two gitlinks and compiles
    # from three of them; the rest are pins of dependencies the build never read, and the aggregators
    # hold three that are not even checked out - so checking all of them warns on every build about
    # something nobody can act on. What reproduces the bytecode is the SOURCES plus the pinned compiler
    # and settings, so a submodule that supplied none of them cannot change the answer, which recovery
    # demonstrates by building while reporting exactly those three unplaced.
    #
    # Each gitlink is THE RECORD's, and its checkout is the first `checkouts_of` offers that holds it: a
    # gitlink names a commit, and any checkout of that repository holding it gives the same bytes. That
    # is what reads harbor's 153 records built from `lib/bao-base-audit-2025-07` - bao-base at the audit
    # tag, a mount since removed from the tree - out of `lib/bao-base`. When none holds it, the first
    # checkout of the repository that exists is taken anyway, so the commit is asked for there and
    # reported missing: a pin that went away. None only when the tree has no checkout of the repository
    # at all, which is a clone that cannot answer.
    #
    # Parents before children, so a nested submodule is looked for from its parent's checkout at the
    # parent's gitlink. Resolved once per distinct commit and submodule set, not per baseline: ten
    # commits carry harbor's 154 records.
    checkouts = checkouts_by_repository(repo_root)
    resolved: dict[tuple[str, tuple[tuple[str, str], ...]], dict[str, tuple[str, Path | None]]] = {}
    placed: dict[str, dict[str, tuple[str, Path | None]]] = {}
    for baseline in present:
        question = (
            baseline.commit,
            tuple(
                sorted(
                    (path, gitlink)
                    for path, gitlink in baseline.submodules.items()
                    if any(source.startswith(f"{path}/") for source in baseline.sources)
                )
            ),
        )
        if question not in resolved:
            submodules: dict[str, tuple[str, Path | None]] = {}
            for path, gitlink in sorted(question[1], key=lambda item: len(item[0])):
                _, parent_repo, parent_commit, inside = placement(repo_root, baseline.commit, path, submodules)
                checkout = None
                if parent_repo is not None:
                    for candidate in checkouts_of(parent_repo, parent_commit, inside, checkouts):
                        if holds(candidate, gitlink):
                            checkout = candidate
                            break
                        if checkout is None and (candidate / ".git").exists():
                            checkout = candidate
                submodules[path] = (gitlink, checkout)
            resolved[question] = submodules
        placed[key(baseline.chainId, baseline.address)] = resolved[question]
    inputs_missing, inputs_unchecked = _inputs_gone(repo_root, present, placed)
    # The name check reads a source's bytes at its commit, so it asks only where those ARE the recorded
    # bytes. A source not checked, or not what was built, is already reported as that; its name at the
    # commit would be a finding about some other file than the one deployed.
    inputs_reported: dict[str, set[str]] = {}
    for baseline, paths in (*inputs_missing, *inputs_unchecked):
        inputs_reported.setdefault(key(baseline.chainId, baseline.address), set()).update(paths)
    # The tags compared with what the record derives, and the labels they need, all from this clone.
    record = list(baselines.values())
    derived = derived_tags(record)
    labels = read_labels(repo_root)
    errors = label_errors(labels, derived)
    in_error = {tag for tag, _ in errors}
    held = _held_tags(repo_root)
    wrong: list[tuple[str, str]] = []
    for tag, built in derived.items():
        if tag in held and tag not in in_error:
            if faults := _faults(repo_root, tag, held[tag], built, str(labels[tag])):
                wrong.append((tag, ", ".join(faults)))
    return Review(
        wrong_tags=wrong,
        label_errors=errors,
        stale_tags=stale_tags(repo_root, record),
        replaced_tags=replaced_tags(repo_root, record),
        missing_tags={tag: built for tag, built in derived.items() if tag not in held},
        recorded=[baselines[k] for k in sorted(baselines) if k in claimed],
        unrecovered=unrecovered,
        unreadable=unreadable,
        orphaned=[baselines[k] for k in sorted(baselines) if k not in claimed],
        conflicts=conflicts,
        inputs_missing=inputs_missing,
        inputs_unchecked=inputs_unchecked,
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
            and baselines[k].source not in inputs_reported.get(k, set())
            and (declared := declared_in(repo_root, baselines[k].commit, baselines[k].source, placed[k]))
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
