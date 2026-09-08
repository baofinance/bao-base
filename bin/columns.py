#!/usr/bin/env python3
"""Align the rows of one group into columns.

Used by every report that lays facts side by side - `bin/dependency-conflicts.py`'s cross-repo table
and `bin/doctor.py`'s version findings - so a reader meets one column discipline rather than one per
script. The two reports are not the same data and are not merged: a cross-repo comparison and a
within-repo disagreement answer different questions. What is shared is the alignment.

ONE GROUP AT A TIME is the whole design. Widths are the widest cell in the rows handed over, so a
caller that calls this once per group gets per-group widths without asking for them - and one long
value cannot pad an unrelated group. Aligning a whole report at once padded every `v1.9.5` in it by
the twenty-four spaces a lone `deploy/harbor-1.1-223-g0d965ca` needed.

WHICH DATUM GOES IN WHICH COLUMN is the caller's, and cannot be enforced here: put the
predictable-width columns first and the variable-width one last. A version and a date have a known
size; a repository path and a note do not, and a variable column in the middle moves everything after
it on every row.
"""

from __future__ import annotations

from collections.abc import Sequence


def rows(cells: Sequence[Sequence[str]], indent: str = "", gap: str = "  ") -> list[str]:
    """The rows, each column padded to the widest cell in this group.

    The last column is never padded and every line is right-stripped, so a row whose trailing cells
    are empty ends where its content does rather than in a run of spaces that a diff or a terminal
    selection then carries around.
    """
    if not cells:
        return []
    widths = [max(len(row[index]) if index < len(row) else 0 for row in cells) for index in range(max(map(len, cells)))]
    return [
        (indent + gap.join(cell.ljust(widths[index]) for index, cell in enumerate(row))).rstrip() for row in cells
    ]
