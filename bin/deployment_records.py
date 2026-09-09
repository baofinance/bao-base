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

TWO LAYERS, deliberately separate. `read_records` reports what a record SAYS - a path comes back
exactly as written, `@bao/` or bare `src/` intact - because nothing can report on a record it has
already reinterpreted. `normalise` then says what a record MEANS, and is where every judgement and
every failure lives.
"""

from __future__ import annotations

import json
import subprocess
import tomllib
from dataclasses import dataclass, replace
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
    # Filled by `normalise`. Kept BESIDE `recorded_path` rather than replacing it: what a record says
    # is a fact about the record, and a finding that cannot quote it cannot be acted on.
    normalised_path: str | None = None


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


def _not_ignored(repo_root: Path, paths: list[Path]) -> list[Path]:
    """`paths` without the ones git ignores, asked in one call.

    `git check-ignore` exits 1 when NOTHING matches, which is the ordinary case and not an error - so
    the return code is not consulted, only the output. Asking per file would be one process each."""
    if not paths:
        return []
    done = subprocess.run(
        ["git", "check-ignore", "--stdin"],
        cwd=repo_root,
        input="\n".join(str(p.relative_to(repo_root)) for p in paths),
        capture_output=True,
        text=True,
    )
    ignored = {repo_root / line for line in done.stdout.splitlines() if line}
    return [p for p in paths if p not in ignored]


def read_records(repo_root: Path) -> list[Entry]:
    """Every deployed contract this repository records, from every manifest under `deployments/`.

    Read from the FILESYSTEM minus what git ignores - not from the index. The distinction matters
    because this is read by a manually-run script that has to see a record a deploy has just written
    and not yet staged; taking the index would hide a fresh deploy's own output from the tool whose
    job is to check it.

    IGNORED is the right exclusion, and it is a real one: harbor gitignores `deployments/local*/`,
    where a local fork deploy leaves a state file indistinguishable from the real thing, and reading
    it reported findings against one machine's scratch.

    A file that describes no deployed contract yields nothing and needs no exclusion list: harbor's
    per-market `harbor_v1::ETH::fxUSD.json` holds deploy CONFIGURATION under `contracts` (fee
    receivers, minter bands, salts), and forge's broadcast files hold transactions - neither has a
    section this recognises. Dispatching on the sections rather than on a list of known filenames is
    what makes that automatic, and what stops a new manifest being silently skipped."""
    deployments = repo_root / "deployments"
    if not deployments.is_dir():
        return []
    present = sorted(deployments.rglob("*.json"))
    found: list[Entry] = []
    for manifest in _not_ignored(repo_root, present):
        try:
            document = json.loads(manifest.read_text())
        except (json.JSONDecodeError, OSError):
            # Unreadable is not "absent": say so rather than quietly returning a shorter list, which
            # would read as "this repo deploys less than it does".
            raise
        if isinstance(document, dict):
            found.extend(_entries(document, manifest, repo_root))
    return found


# ── normalising: what a record MEANS ──────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Problem:
    """A record that cannot be normalised, and why. Carries the entry so a report can quote what the
    record actually says - a finding a human cannot trace back to a file and a line is not actionable."""

    entry: Entry
    reason: str


def _remapping_prefixes(repo_root: Path) -> list[tuple[str, str]]:
    """(target, prefix) for every remapping whose target is a directory of THIS repo, longest first.

    Read from `foundry.toml` rather than hardcoded, because the prefix a repo uses for its own source
    is the repo's to choose - `@harbor/`, `@harbor-price/`, `@bao/` - and a table here would be a copy
    that drifts the first time one of them changes.

    Targets under `lib/` are INCLUDED. They were excluded, and that was wrong: `@bao/=lib/bao-base/src/`
    is exactly how harbor's 46 bao-base-sourced records are already written, so refusing to produce
    that form made them unrepresentable - and it left this holding the opposite answer to `source_at`,
    which searches `lib/` because a contract defined in a dependency is defined there."""
    toml = repo_root / "foundry.toml"
    if not toml.is_file():
        return []
    with toml.open("rb") as stream:
        profiles = tomllib.load(stream).get("profile", {})
    found: list[tuple[str, str]] = []
    for entry in profiles.get("default", {}).get("remappings", []):
        prefix, _, target = entry.partition("=")
        # A context remapping (`context:prefix=target`) applies to only part of the tree, so it cannot
        # be inverted into a name for a path in general.
        if not target or ":" in prefix:
            continue
        found.append((target, prefix))
    return sorted(found, key=lambda pair: -len(pair[0]))


def _paths_ever(repo_root: Path) -> set[str]:
    """Every path this repository has ever held, across all refs.

    One `git log` rather than one per entry: 462 records over five repos is 462 subprocesses, and this
    answers all of them at once. Membership is what separates a path that MOVED - the ordinary case,
    since records are historical and `v3-oracles.json`'s eleven paths have all moved - from a path
    this repo never had, which is the failure."""
    done = subprocess.run(
        ["git", "log", "--all", "--pretty=format:", "--name-only"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    return {line for line in done.stdout.splitlines() if line}


def normalise(entries: list[Entry], repo_root: Path) -> tuple[list[Entry], list[Problem]]:
    """Entries with `chain` and `normalised_path` settled, and the ones that could not be.

    Chain is lowercased: eight spellings for four chains were found across the aggregators' manifests
    (`Mainnet`/`mainnet`, `MegaETH`/`megaeth`), the cased ones from the records' own fields and the
    lowercase from the directories they sit in. Lowercase is what the directories and the source tree
    already use, so it is the form that agrees with everything else.

    A path already carrying a prefix is left alone. A bare path is given the prefix its repo uses for
    that directory, and is then checked against every path this repo has ever held - because a bare
    path silently means "this repo", and harbor's `src/BaoPauser_v1.sol` means bao-base's `src/`.
    THAT is what fails here, and it fails rather than guessing: no prefix can be invented for a file
    that was never in this repository."""
    normalised: list[Entry] = []
    problems: list[Problem] = []
    ever = _paths_ever(repo_root)
    prefixes = _remapping_prefixes(repo_root)

    for entry in entries:
        settled = replace(entry, chain=entry.chain.lower())
        path = entry.recorded_path
        if path is None:
            # Already reported as a gap by the reader; it is not additionally a normalisation failure.
            normalised.append(settled)
            continue
        if path.startswith("@"):
            normalised.append(replace(settled, normalised_path=path))
            continue
        for target, prefix in prefixes:
            if path.startswith(target):
                # The history check is for THIS repository's own bare paths, which is the ambiguity it
                # exists to catch: harbor's `src/BaoPauser_v1.sol` naming bao-base's file. A
                # dependency's files are never in the parent's history, so applying it there would
                # reject every one of them - and the prefix is unambiguous by construction anyway,
                # because it names the dependency.
                if not target.startswith("lib/") and path not in ever:
                    problems.append(
                        Problem(
                            entry,
                            f"no file at {path} has ever been in this repository, so the bare path "
                            f"cannot mean this repo's {target} - name the repo it belongs to",
                        )
                    )
                    break
                normalised.append(replace(settled, normalised_path=prefix + path[len(target) :]))
                break
        else:
            problems.append(Problem(entry, f"no remapping in foundry.toml covers {path}"))
    return normalised, problems
