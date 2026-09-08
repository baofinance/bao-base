#!/usr/bin/env python3
"""Report dependencies this repository and a repository of ours each stage at a different commit.

Part of `verify-audit` rather than `yarn doctor`, because it can be legitimately red: staging a newer
OpenZeppelin than bao-base is what a staged upgrade LOOKS like, and a check that is red for the whole
of a deliberate migration is one people learn to ignore. It belongs where it is read at decision time,
qualifying the verdicts around it — the guarantees a dependency established were made against ITS
pins and are spent against ours.

Prints, and never fails the run: which side moves is a judgement, and often the answer is that neither
should yet. `submodule_state.conflicting_dependencies` holds the reading; this only lays it out.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from submodule_state import Mismatch, conflicting_dependencies  # noqa: E402

# What ancestry established, always stated RELATIVE TO HERE and only ever on the other repository's
# line. A group can hold three parties - forge-std has us between bao-factory and the rest - and a
# note on our own line would then have to be true of one of them and false of another. Each of these
# is pairwise true, which is all ancestry ever claimed.
RELATIVE = {
    "ours is later": "behind this repo",
    "theirs is later": "ahead of this repo",
    "diverged": "diverged from this repo",
    "unrelated histories": "",  # no shared commit to order by; the version and date carry it
}


def _side(pinned, where: str, note: str = "") -> tuple[str, str, str, str]:
    """One line's columns: the version first, then the date, then the text whose width cannot be
    predicted. Anything variable at the END is what keeps the columns readable when a describe is
    `deploy/harbor-1.1-223-g0d965ca` and the one below it is `v1.9.5`."""
    return pinned.described or (pinned.commit or "?")[:10], (pinned.when or "")[:10], where, note


def report(found: list[Mismatch]) -> str:
    """The findings, or "" when there are none.

    Silent on agreement because the caller says so instead, through the same `log` every other INFO
    line in a run comes from - one convention for one kind of line, rather than this inventing a
    second that looks nearly the same but is not."""
    if not found:
        return ""

    # Grouped by dependency, because more than one repository of ours can disagree about the same one
    # and they all disagree with the SAME pin of ours - so "here" is said once and each of them under
    # it. Widths are per group, not across the report: one `deploy/harbor-1.1-223-g0d965ca` would
    # otherwise pad every `v1.9.5` in it by twenty-four spaces.
    grouped: dict[str, list[Mismatch]] = {}
    for mismatch in found:
        grouped.setdefault(mismatch.dependency, []).append(mismatch)

    lines = [
        f"{len(grouped)} dependenc{'y' if len(grouped) == 1 else 'ies'} staged in this repo at a "
        "different commit than by a repository it depends on:",
        "",
    ]
    for dependency, mismatches in grouped.items():
        rows = [_side(mismatches[0].ours, "this repo")]
        rows += [
            _side(mismatch.theirs, mismatch.at, RELATIVE.get(mismatch.relation or "", "")) for mismatch in mismatches
        ]
        version_width = max(len(row[0]) for row in rows)
        where_width = max(len(row[2]) for row in rows)

        lines.append(f"  {dependency}")
        lines.extend(
            f"    {version:<{version_width}}  {when:<10}  {where:<{where_width}}  {note}".rstrip()
            for version, when, where, note in rows
        )
        if any(mismatch.relation is None for mismatch in mismatches):
            lines.append("    (no checkout holds both commits, so which is later cannot be read here)")
        lines.append("")
    lines.append("  run `yarn update <dependency>@<ref>` in whichever repo is the one to move")
    return "\n".join(lines)


def main() -> int:
    """Non-zero when anything disagrees. A mismatch is a defect, not a note: repositories sharing
    bao-base are meant to be on one version of each thing they share, and every finding is one
    `yarn update` from gone - in whichever of the two repositories is the one to move. It is red until
    they converge, which is the point of saying it."""
    found = conflicting_dependencies(Path.cwd())
    if found:
        print(report(found))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
