#!/usr/bin/env python3
"""Fail when two source files compile a contract of the same name.

The artefact namespace is flat: forge writes every contract to out/<file>.sol/<Contract>.json, so two
declarations of one name resolve to one path and the second overwrites the first. Nothing warns. The
survivor is then what `--match-contract`, the size/gas/coverage tables, and anything reading an
artifact by name will read - including verify-audit's bytecode comparison, which looks its artifact up
by basename and so compares the wrong contract.

Read from out/build-info/ rather than from out/ itself, because a collision hides from every other
build output: the artifact directory has already collapsed it, `forge build --sizes --json` omits it,
and slither's name-reused detector reports nothing. build-info keys output.contracts by SOURCE PATH,
so both declarations survive there - and the report can name both paths, which is what makes a failure
actionable. (`forge inspect <name>` also still detects it, resolving over the source graph, but it
names only the contract.)

Any collision fails. This is a defect, not a measurement: there is no meaningful "no worse than
before" for two contracts sharing a name, so there is no baseline to ratchet and no accepted-exception
list to maintain. A repo that still has collisions stays red until they are gone, and the report says
which ones remain.
"""

import json
import sys
from collections import defaultdict
from pathlib import Path


class NothingToCheck(Exception):
    """No build-info was found, so the check examined nothing.

    Never report "no collisions" for this: a check that passes having looked at nothing is the exact
    failure this tool exists to remove.
    """


def collisions(build_info_dir: Path, root: Path = Path(".")) -> dict[str, list[str]]:
    """Contract names declared by more than one source file, each mapped to every path declaring it.

    `root` is where the source paths in build-info are resolved from, so a caller can point the check
    at a tree other than the working directory.
    """
    build_info_dir = Path(build_info_dir)
    files = sorted(build_info_dir.glob("*.json")) if build_info_dir.is_dir() else []
    if not files:
        raise NothingToCheck(
            f'no build-info in "{build_info_dir}" - run `forge build --build-info` first '
            "(this repo sets build_info = true, so an ordinary build writes it)"
        )

    paths_by_name: dict[str, set[str]] = defaultdict(set)
    for build_info in files:
        contracts = json.loads(build_info.read_text()).get("output", {}).get("contracts", {})
        for source_path, declared in contracts.items():
            # build-info accumulates across builds and is never pruned, so it still names files that
            # have since been moved or deleted. Left in, a move would report the file as colliding
            # with itself at its new path.
            if not (root / source_path).exists():
                continue
            for contract_name in declared:
                paths_by_name[contract_name].add(source_path)

    return {name: sorted(paths) for name, paths in sorted(paths_by_name.items()) if len(paths) > 1}


def format_report(found: dict[str, list[str]]) -> str:
    """The baseline's text, and the report: a contract name, then every path that declares it."""
    lines = []
    for name, paths in found.items():
        lines.append(name)
        lines.extend(f"    {path}" for path in paths)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    """`lint-contract-names [build-info-dir]`, defaulting to the ordinary build's out/build-info."""
    args = sys.argv[1:] if argv is None else argv
    build_info_dir = Path(args[0]) if args else Path("out/build-info")

    try:
        found = collisions(build_info_dir)
    except NothingToCheck as nothing:
        print(f"ERROR: {nothing}", file=sys.stderr)
        return 1

    if not found:
        print("no contract name collisions")
        return 0

    print(format_report(found))
    print(
        f"ERROR: {len(found)} contract name(s) declared by more than one source file; "
        "each must be renamed so every contract in the build has a unique name",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
