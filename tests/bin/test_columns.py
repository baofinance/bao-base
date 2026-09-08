"""bin/columns.py aligns the rows of ONE group.

Every case here is a property of the alignment rather than an expected string: an expected string
would have to be rewritten by whoever changes the gap, and would then assert only that it had been
rewritten. The per-group behaviour has its own test in test_dependency_conflicts.py, where it is a
property of the report; here it is the reason the function takes one group at a time.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from columns import rows  # noqa: E402


def starts(line: str, count: int | None = None) -> list[int]:
    """Where the first `count` columns begin, which is what "aligned" means - and what a length
    assertion cannot catch, since two rows can both be wrong and still match each other.

    Read off the line rather than computed, so it sees what a reader sees. `count` is needed because a
    cell may itself contain a space - "this repo", "behind this repo" - and nothing in the rendered
    line distinguishes that from a column boundary. Every such cell here is the last one, so taking
    the leading columns is exact."""
    found = [index for index, char in enumerate(line) if char != " " and (index == 0 or line[index - 1] == " ")]
    return found[:count]


def test_nothing_to_align_is_no_lines():
    assert rows([]) == []


def test_every_row_starts_its_columns_at_the_same_place():
    laid_out = rows([["v1.10.0", "2025-07-31", "this repo"], ["v1.9.5", "2024-12-19", "lib/harbor"]])

    assert len({tuple(starts(line, 3)) for line in laid_out}) == 1, laid_out


def test_the_widest_cell_sets_its_column():
    laid_out = rows([["deploy/harbor-1.1-223-g0d965ca", "here"], ["v1.9.5", "there"]])

    assert starts(laid_out[1])[1] == starts(laid_out[0])[1], laid_out
    assert laid_out[0].index("here") == laid_out[1].index("there")


def test_a_row_ends_where_its_content_does():
    # The last column is not padded and the line is stripped, so a row whose trailing cells are empty
    # does not end in a run of spaces for a diff or a terminal selection to carry around.
    laid_out = rows([["v1.10.0", "this repo", "behind this repo"], ["v1.9.5", "lib/harbor", ""]])

    assert laid_out[1] == laid_out[1].rstrip()
    assert laid_out[1].endswith("lib/harbor")


def test_short_rows_do_not_have_to_be_padded_by_the_caller():
    # A row with fewer cells than its neighbours is the ordinary case for a trailing annotation, and
    # requiring the caller to pass "" for it would be a rule to remember rather than one enforced.
    laid_out = rows([["v1.10.0", "this repo", "behind this repo"], ["v1.9.5", "lib/harbor"]])

    assert starts(laid_out[0], 2) == starts(laid_out[1], 2), laid_out


def test_the_indent_is_on_every_row_and_is_not_counted_as_content():
    laid_out = rows([["a", "one"], ["bb", "two"]], indent="    ")

    assert all(line.startswith("    ") for line in laid_out)
    assert starts(laid_out[0]) == starts(laid_out[1])
