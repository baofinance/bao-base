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
from collections.abc import Iterable
from dataclasses import asdict, dataclass, replace
from pathlib import Path

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


# Python names on the left, the file's names on the right. The file is camelCase throughout, because
# every manifest in the fleet already is (`contractSource`, `contractType`, `deploymentTime`,
# `chainId`) and a reader moving between them should not have to translate; Python stays snake_case,
# because it is Python. Mixing the two conventions in one file - which the first draft did, with
# `schemaVersion` beside `creation_bytecode_hash` - reads as two authors who never met.
_FIELDS = {
    "chain": "chain",
    "address": "address",
    "contract_type": "contractType",
    "source": "source",
    "commit": "commit",
    "commit_timestamp": "commitTimestamp",
    "deploy_block": "deployBlock",
    "deploy_timestamp": "deployTimestamp",
    "creation_bytecode_hash": "creationBytecodeHash",
}


@dataclass(frozen=True)
class Baseline:
    """One deployed contract's source, as a fact.

    `contract_type` duplicates the manifest's field of that name, deliberately and under the same
    spelling: it is what makes the record readable on its own, it cannot drift because both are
    write-once facts about one immutable artefact, and calling it something else would invite the
    question of whether it means something else. `deployedAt` is NOT duplicated, for the opposite
    reason - harbor's history shows it repaired twice (a null filled in, a date reformatted), so it is
    mutable metadata and copying it would be a copy that can diverge.


    Every timestamp is UTC, written with a `Z`. Both come from Unix seconds - the block's own, and
    `git log --format=%ct` - rather than from any formatter that carries a local offset, so a record
    does not depend on where the person recovering it was sitting.

    `commit_timestamp` beside `deploy_timestamp` is diagnostic, not decoration: a commit made AFTER
    the deploy proves the deploy ran from a tree that was not committed yet, which is the ambiguity
    the tags could never settle. And `deploy_timestamp` is the CHAIN's, where the manifests record the
    deploy script's clock - measured 2m55s late for BaoPauser, and shared across a whole batch of
    aggregators that were deployed at different moments."""

    chain: str
    address: str
    contract_type: str
    source: str  # normalised and repo-qualified, resolvable at `commit`
    commit: str
    commit_timestamp: str
    deploy_block: int
    deploy_timestamp: str
    creation_bytecode_hash: str


def key(chain: str, address: str) -> str:
    """The identity of a deployed contract, as one string.

    Lowercased on both halves. Addresses are checksummed in the manifests, so two spellings of one
    address would otherwise become two baselines for one artefact - the same trap the chain names had,
    where eight spellings covered four chains."""
    return f"{chain.lower()}/{address.lower()}"


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
    return {
        entry_key: Baseline(**{name: fields[spelling] for name, spelling in _FIELDS.items()})
        for entry_key, fields in (document.get("baselines") or {}).items()
    }


def add(baselines: dict[str, Baseline], baseline: Baseline) -> dict[str, Baseline]:
    """`baselines` with `baseline` added. Idempotent, and refuses to replace.

    Re-recording the same fact is a no-op, so a deploy re-run or a recovery pass that covers ground it
    already covered is safe. Recording something DIFFERENT for an address that already has a baseline
    is refused: the artefact at that address never changed, so the two claims cannot both be true and
    this is not the place to decide which is."""
    entry_key = key(baseline.chain, baseline.address)
    existing = baselines.get(entry_key)
    if existing is not None and existing != baseline:
        raise Conflict(
            f"{entry_key} is already recorded as {existing.contract_type} from {existing.commit[:10]}; "
            f"refusing to replace it with {baseline.contract_type} from {baseline.commit[:10]}"
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
        "baselines": {
            entry_key: {spelling: asdict(baselines[entry_key])[name] for name, spelling in _FIELDS.items()}
            for entry_key in sorted(baselines)
        },
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


def review(repo_root: Path) -> Review:
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
    baselines = read_baselines(repo_root)
    claimed = {key(entry.chain, entry.address) for entry in entries}
    return Review(
        recorded=[baselines[k] for k in sorted(baselines) if k in claimed],
        unrecovered=_by_address(e for e in entries if key(e.chain, e.address) not in baselines),
        unreadable=unreadable,
        orphaned=[baselines[k] for k in sorted(baselines) if k not in claimed],
    )


def _by_address(entries: Iterable[Entry]) -> list[Entry]:
    """One entry per deployed contract, taking each field from whichever manifest supplied it.

    A contract is often described by two manifests: 44 of the aggregators' 85 addresses are in both
    `v3-aggregators.json` and `v3-oracles.json`, and only the first carries `deploymentTime`. Listed
    separately they became two things to recover, one of which reported "no deployment time recorded"
    while the time sat in the other row - 64 of 152 outcomes in the first run.

    It is the same rule as everywhere else here: the ADDRESS is the identity of a deployed contract, so
    two rows about one address are two descriptions of one thing, not two things."""
    merged: dict[str, Entry] = {}
    for entry in entries:
        entry_key = key(entry.chain, entry.address)
        held = merged.get(entry_key)
        if held is None:
            merged[entry_key] = entry
            continue
        merged[entry_key] = replace(
            held,
            name=held.name or entry.name,
            recorded_path=held.recorded_path or entry.recorded_path,
            normalised_path=held.normalised_path or entry.normalised_path,
            deployed_at=held.deployed_at or entry.deployed_at,
        )
    return list(merged.values())
