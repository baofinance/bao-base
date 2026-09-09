#!/usr/bin/env python3
"""Read every deployment record in a repository into one shape.

A deployment record says which contract was deployed, at which address, from which source. Five repos
write them in two formats through two unrelated writers - one shared Solidity serializer behind
`run-script.py` (bao-base, harbor, harbor-yield, harbor-swap) and sixteen bash scripts
(harbor-price-aggregators) - so anything that wants to ASK about deployed contracts has to understand
both. This is that understanding, in one place, so the question can be asked once.

Distinct from `verify-audit.py`'s `_manifest_paths`, which harvests every value of one named field
wherever it occurs and is deliberately shape-agnostic ("the manifest's shape is the deploy's
business"). That answers "which paths", and cannot pair an address with a name and a path, which is
what identifying a deployed contract requires: the address is the identity of the deployed thing, the
name the identity of its source, and the path a fact about the tree at the moment it was written.

WHAT IS NOT HERE. No resolution and no judgement: a recorded path is returned exactly as written, with
its `@bao/` or bare `src/` prefix intact and no attempt to find it in any tree. Both are ambiguous -
harbor records `src/BaoPauser_v1.sol` for a file in bao-base - and resolving them needs a remapping
table AND the commit it applied at, neither of which a record carries today. Reading has to be
separable from that, or nothing can report what a record actually says.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

# The sections a record can carry, and the field each spells its source path with. Dispatch is on
# WHICH KEYS ARE PRESENT, never on the file's name: `v3-oracles.json` carries both sections, and its
# `implementations` entries hold a `contractName` and no path at all - so a reader keyed on the
# filename reads the wrong section and silently gets nothing.
_SECTIONS = {
    "implementations": ("contractSource", "contractType"),
    "oracles": ("contractPath", None),  # name comes from the path's ":Name" suffix
}


@dataclass(frozen=True)
class Entry:
    """One deployed contract, as one record describes it.

    `recorded_path` and `name` are optional because records exist that carry one without the other -
    `v3-oracles.json`'s `implementations` entries name a contract and give no path, which is a
    deployed contract nothing can currently baseline. That is worth returning as a gap rather than
    dropping, so it can be reported."""

    address: str
    name: str | None
    recorded_path: str | None
    chain: str
    deployed_at: str | None
    manifest: str  # repo-relative, so a finding can name the file a human has to edit
    section: str


def _chain(document: dict, manifest: Path, repo_root: Path) -> str:
    """What chain a record is about.

    Format A says `network`, format B says `chainName`, and a record written before either says
    neither - so the containing directory is the last resort, which is how these are organised
    (`deployments/mainnet/…`). `chainId` is deliberately not used as a fallback: it is a number that
    would then have to be mapped back to a name here, duplicating a table that belongs elsewhere."""
    for key in ("network", "chainName"):
        value = document.get(key)
        if isinstance(value, str) and value:
            return value
    parent = manifest.parent
    return parent.name if parent != repo_root else ""


def _entries(document: dict, manifest: Path, repo_root: Path) -> list[Entry]:
    chain = _chain(document, manifest, repo_root)
    display = str(manifest.relative_to(repo_root))
    found: list[Entry] = []
    for section, (path_field, name_field) in _SECTIONS.items():
        entries = document.get(section)
        if not isinstance(entries, dict):
            continue
        for key, entry in entries.items():
            if not isinstance(entry, dict):
                continue
            recorded = entry.get(path_field)
            name = entry.get(name_field) if name_field else None
            if recorded and not name_field:
                # Format B fuses them: "src/…/Aggregator_stETH_USD_mainnet.sol:Aggregator_stETH_USD_mainnet"
                recorded, _, name = recorded.partition(":")
            # An entry naming neither a path nor a contract is not describing a deployed contract at
            # all - a `proxies` entry, or configuration that happens to sit under the same key.
            name = name or entry.get("contractName")
            if not recorded and not name:
                continue
            found.append(
                Entry(
                    # Format A keys by address; format B keys by symbol and carries the address in
                    # the entry. The address is the identity either way, so it is read from wherever
                    # that format put it.
                    address=entry.get("address") or key,
                    name=name,
                    recorded_path=recorded or None,
                    chain=chain,
                    deployed_at=entry.get("deploymentTime") or entry.get("deployedAt"),
                    manifest=display,
                    section=section,
                )
            )
    return found


def read_records(repo_root: Path) -> list[Entry]:
    """Every deployed contract this repository records, from every manifest under `deployments/`.

    A file that describes no deployed contract yields nothing and needs no exclusion list: harbor's
    per-market `harbor_v1::ETH::fxUSD.json` holds deploy CONFIGURATION under `contracts` (fee
    receivers, minter bands, salts), and forge's broadcast files hold transactions - neither has a
    section this recognises. Dispatching on the sections rather than on a list of known filenames is
    what makes that automatic, and what stops a new manifest being silently skipped."""
    deployments = repo_root / "deployments"
    if not deployments.is_dir():
        return []
    found: list[Entry] = []
    for manifest in sorted(deployments.rglob("*.json")):
        try:
            document = json.loads(manifest.read_text())
        except (json.JSONDecodeError, OSError):
            # Unreadable is not "absent": say so rather than quietly returning a shorter list, which
            # would read as "this repo deploys less than it does".
            raise
        if isinstance(document, dict):
            found.extend(_entries(document, manifest, repo_root))
    return found
