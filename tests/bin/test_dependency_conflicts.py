"""bin/dependency-conflicts.py lays out what `submodule_state.conflicting_dependencies` read.

Only the layout is tested here - the reading has its own tests, against real git trees, in
test_submodule_state.py. So these build `Mismatch` values directly: a fixture that went near git would
test the reader again and say nothing about the columns.

The columns are the point. Every one of the cases below is something that was wrong at some stage
while this was written, and each was found by looking at a real repository rather than by thinking
about it - one long `describe` padding an unrelated group by twenty-four spaces, and a three-party
group whose annotations contradicted each other.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BAO_BASE / "bin"))

from submodule_state import Mismatch, Pinned  # noqa: E402

# Imported by path because the filename is hyphenated, as every executable in bin/ is.
_spec = importlib.util.spec_from_file_location("dependency_conflicts", BAO_BASE / "bin" / "dependency-conflicts.py")
dependency_conflicts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dependency_conflicts)
report = dependency_conflicts.report


def mismatch(dependency: str, at: str, ours: str, theirs: str, relation: str | None) -> Mismatch:
    return Mismatch(
        dependency=dependency,
        at=at,
        ours=Pinned("a" * 40, ours, "2025-10-08T11:12:33+03:00"),
        theirs=Pinned("b" * 40, theirs, "2024-12-19T18:14:25+02:00"),
        relation=relation,
    )


def columns(line: str) -> list[int]:
    """Where each column starts, which is what "aligned" means and what a length assertion cannot
    catch: two rows can both be wrong and still match each other."""
    return [index for index, char in enumerate(line) if char != " " and (index == 0 or line[index - 1] == " ")]


def rows(found: str) -> list[str]:
    """The indented lines carrying a version, excluding headings and the closing advice."""
    return [line for line in found.splitlines() if line.startswith("    ") and not line.startswith("    (")]


def where(row: str) -> str:
    """A row's third column onwards - the repository, plus any annotation. Parsed rather than matched
    as a substring, because "this repo" also appears in the heading and inside "behind this repo"."""
    return " ".join(row.split()[2:])


def test_agreement_says_nothing_here(tmp_path):
    # The caller announces it through `log`, so that every INFO line in a run comes from one place.
    assert report([]) == ""


def test_one_repository_disagreeing_names_both_sides(tmp_path):
    found = report([mismatch("solady", "lib/bao-base", "v0.1.26", "v0.0.287", "ours is later")])

    assert "solady" in found
    assert "v0.1.26" in found and "v0.0.287" in found
    assert "this repo" in found and "lib/bao-base" in found


def test_repositories_disagreeing_about_one_dependency_share_a_single_line_for_ours(tmp_path):
    # harbor-yield's shape: two of ours disagree about the same dependency, and both disagree with the
    # SAME pin of ours. Repeating it would say the same thing twice and read as two problems.
    found = report(
        [
            mismatch("forge-std", "lib/harbor", "v1.10.0", "v1.9.5", "ours is later"),
            mismatch("forge-std", "lib/bao-base", "v1.10.0", "v1.9.5", "ours is later"),
        ]
    )

    assert [where(row) for row in rows(found)].count("this repo") == 1, found
    assert found.count("forge-std") == 1, "one heading, not one per disagreement"
    assert "lib/harbor" in found and "lib/bao-base" in found


def test_a_long_version_does_not_pad_another_group(tmp_path):
    # A `describe` with no tag on it is thirty characters - `deploy/harbor-1.1-223-g0d965ca`. Aligning
    # across the whole report made every `v1.9.5` elsewhere carry twenty-four trailing spaces.
    found = report(
        [
            mismatch(
                "bao-base", "lib/harbor", "deploy/harbor-1.1-223-g0d965ca", "deploy/harbor-1.1-196-g998dc0f", None
            ),
            mismatch("solady", "lib/bao-base", "v0.1.26", "v0.0.287", "ours is later"),
        ]
    )

    # Each group sets its own width, so the date starts further right in the group holding the long
    # describe than in the group of short tags. One width across the report would put them level.
    long_group = [row for row in rows(found) if "deploy/harbor" in row][0]
    short_group = [row for row in rows(found) if "v0.1.26" in row][0]

    assert columns(long_group)[1] > columns(short_group)[1], (long_group, short_group)


def test_rows_within_one_group_line_up(tmp_path):
    found = report(
        [
            mismatch("forge-std", "lib/harbor", "v1.10.0", "v1.9.5", "ours is later"),
            mismatch("forge-std", "lib/bao-factory", "v1.10.0", "v1.12.0", "theirs is later"),
        ]
    )

    assert len({tuple(columns(row)[:3]) for row in rows(found)}) == 1, rows(found)


def test_only_the_other_repository_is_annotated(tmp_path):
    # The bug this exists to stop. With us between two of them, annotating our own line made the
    # report say "behind" and "ahead" of the same pin - each true of one, and read as a contradiction.
    found = report(
        [
            mismatch("forge-std", "lib/harbor", "v1.10.0", "v1.9.5", "ours is later"),
            mismatch("forge-std", "lib/bao-factory", "v1.10.0", "v1.12.0", "theirs is later"),
        ]
    )

    ours_line = [row for row in rows(found) if where(row) == "this repo"][0]
    assert "behind" not in ours_line and "ahead" not in ours_line, ours_line
    assert "behind this repo" in found and "ahead of this repo" in found


def test_unrelated_histories_carry_no_claim_about_order(tmp_path):
    # openzeppelin-contracts-upgradeable is transpiled per release, so two versions share no commit.
    # An ordinary version gap, and calling it divergence would alarm about every OZ upgrade there is.
    found = report(
        [mismatch("openzeppelin-contracts-upgradeable", "lib/bao-base", "v5.6.1", "v5.7.0", "unrelated histories")]
    )

    assert "diverged" not in found
    assert "behind" not in found and "ahead" not in found
    assert "v5.6.1" in found and "v5.7.0" in found, "the versions and dates have to carry it instead"


def test_a_pin_that_cannot_be_ordered_says_so(tmp_path):
    # No checkout held both commits, and a read-only reader must not fetch to find out.
    found = report([mismatch("bao-base", "lib/harbor", "abcdef1234", "9876543210", None)])

    assert "cannot be read here" in found
