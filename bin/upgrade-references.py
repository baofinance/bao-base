#!/usr/bin/env python3
"""upgrade-references: the latest version of each upgradeable family names its predecessor.

Without `@custom:oz-upgrades-from`, OpenZeppelin validates a contract in ISOLATION and never checks its
storage layout is compatible with the version before it — a silent gap (a re-ordered or inserted
namespaced field would ship unverified). A contract may instead carry `@custom:bao-upgrades-from`, which
OpenZeppelin ignores and bin/storage-successor.py verifies. Either names `<path>:<Family>_v<N>`, and a
contract declares at most one.

Only the LATEST version (the highest `_v<N>`, N >= 2, of its family) must name one: the upgrade still to
be performed is from the deployed version to the latest, and an older version's link re-checks an upgrade
already made. An older version may keep its annotation, and every annotation present is checked for form
here — but OpenZeppelin follows every one it finds, so what it names must still compile. Parking a
version therefore means deleting the annotation that names it.

Whether the latest names the version actually deployed (v3 never shipped, so v4 should name v2) is not
checked: the report holds names only.

Reads the report of OpenZeppelin upgrades-core `validate`, which lists each upgradeable contract on a
line of its own and appends "(upgrades from <path>:<Name>)" exactly when the contract carries
`@custom:oz-upgrades-from`, and the `<successor> <predecessor>` lines of `storage-successor --list` for
the bao links. Only contracts whose path starts with `--scope` are audited: the discipline is for the
production versioned contracts, not for a script/ contract whose name happens to end in "_v<n>".

Exit 0 if every audited contract passes; 1 otherwise.
"""

import argparse
import re
import sys
from pathlib import Path

from rich.console import Console

# a contract line of the report: a pass/fail mark, the contract, and its predecessor when it names one
_CONTRACT_LINE = re.compile(
    r"^\s*[✔✘]\s+(?P<path>\S+\.sol):(?P<name>[A-Za-z_]\w*)"
    r"(?: \(upgrades from \S+\.sol:(?P<predecessor>[A-Za-z_]\w*)\))?\s*$"
)
# the report's closing count, against which the parsed lines are checked
_DETECTED = re.compile(r"\((?P<count>\d+) upgradeable contracts? detected")
_VERSIONED = re.compile(r"^(?P<family>.+)_v(?P<version>\d+)$")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check versioned upgradeable contracts name their predecessor.")
    parser.add_argument("report", type=Path, help="the output of OpenZeppelin upgrades-core validate")
    parser.add_argument("--bao-links", type=Path, required=True, help="the output of storage-successor --list")
    parser.add_argument("--scope", required=True, help="audit only contracts whose path starts with this")
    args = parser.parse_args(argv)

    report = args.report.read_text()
    contracts = [match for match in map(_CONTRACT_LINE.match, report.splitlines()) if match]
    detected = _DETECTED.search(report)
    if detected is None:
        sys.exit(f"upgrade-references: {args.report} has no 'upgradeable contracts detected' count")
    if int(detected["count"]) != len(contracts):
        sys.exit(
            f"upgrade-references: {args.report} reports {detected['count']} upgradeable contracts "
            f"but {len(contracts)} contract lines were read from it"
        )
    bao_predecessor = dict(line.split() for line in args.bao_links.read_text().splitlines() if line.strip())

    # unwrapped, so each finding stays one line a log can be searched for; the terminal wraps it for display
    console = Console(soft_wrap=True)
    audited = [
        (contract, versioned)
        for contract in contracts
        if contract["path"].startswith(args.scope) and (versioned := _VERSIONED.match(contract["name"]))
    ]
    latest: dict[str, int] = {}
    for _contract, versioned in audited:
        latest[versioned["family"]] = max(latest.get(versioned["family"], 0), int(versioned["version"]))
    failed = False
    for contract, versioned in audited:
        name = contract["name"]
        family = versioned["family"]
        version = int(versioned["version"])
        oz_predecessor = contract["predecessor"]
        bao = bao_predecessor.get(name)
        if oz_predecessor is not None and bao is not None:
            message = f"{name}: declares BOTH @custom:oz-upgrades-from and @custom:bao-upgrades-from — use exactly one"
        elif oz_predecessor is not None or bao is not None:
            predecessor = oz_predecessor if oz_predecessor is not None else bao
            tag = "oz" if oz_predecessor is not None else "bao"
            predecessor_versioned = _VERSIONED.match(predecessor)
            if predecessor_versioned is None or predecessor_versioned["family"] != family:
                message = f"{name}: @custom:{tag}-upgrades-from references a non-{family}_v* contract ({predecessor})"
            else:
                console.print(f" ✔  {name} upgrades from {predecessor}{' (bao)' if tag == 'bao' else ''}", markup=False)
                continue
        elif version < 2:
            continue
        elif version < latest[family]:
            console.print(
                f" ✔  {name} names no predecessor, which only the latest, {family}_v{latest[family]}, must",
                style="dim",
                markup=False,
            )
            continue
        else:
            message = (
                f"{name}: no @custom:oz-upgrades-from or @custom:bao-upgrades-from reference — "
                "its storage layout is NOT validated against the deployed predecessor"
            )
        console.print(f" ✘  {message}", style="red", markup=False)
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
