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
from dataclasses import asdict, dataclass
from pathlib import Path

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


@dataclass(frozen=True)
class Baseline:
    """One deployed contract's source, as a fact.

    `contract` duplicates the manifest's `contractType` and that is deliberate: it is what makes the
    record readable on its own, and it cannot drift, because both are write-once facts about one
    immutable artefact. `deployedAt` is NOT duplicated for the opposite reason - harbor's history shows
    it repaired twice (a null filled in, a date reformatted), so it is mutable metadata and copying it
    would be a copy that can diverge."""

    chain: str
    address: str
    contract: str
    source: str  # normalised, repo-qualified: "@bao/BaoPauser_v1.sol"
    commit: str
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
        entry_key: Baseline(**fields) for entry_key, fields in (document.get("baselines") or {}).items()
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
            f"{entry_key} is already recorded as {existing.contract} from {existing.commit[:10]}; "
            f"refusing to replace it with {baseline.contract} from {baseline.commit[:10]}"
        )
    return {**baselines, entry_key: baseline}


def write_baselines(repo_root: Path, baselines: dict[str, Baseline]) -> None:
    """Write the record, sorted by key.

    Sorted so that two deploys racing collide as two disjoint ADDITIONS a human can resolve by eye,
    rather than as a reordering of the whole file. A trailing newline because every other file in the
    tree has one and a diff that says "no newline at end of file" wastes a reader's attention."""
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "baselines": {
            entry_key: {name: value for name, value in asdict(baselines[entry_key]).items()}
            for entry_key in sorted(baselines)
        },
    }
    (repo_root / RECORD).write_text(json.dumps(document, indent=2) + "\n")
