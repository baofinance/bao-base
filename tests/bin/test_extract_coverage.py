import importlib.util
import pathlib
import re

import pytest


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "extract-coverage.py"
    spec = importlib.util.spec_from_file_location("extract_coverage", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


# Rows the extractor keeps: under src/ or script/, not a deploy stub, not a verification one-shot.
KEPT = [
    "| src/KeptOne.sol         | 50.00% (10/20)   | 50.00% (5/10)    | 50.00% (2/4)   | 50.00% (1/2)     |",
    "| script/KeptTwo.sol      | 25.00% (5/20)    | 20.00% (2/10)    | 25.00% (1/4)   | 50.00% (1/2)     |",
]

# Rows the extractor drops, one per exclusion rule. Each is fully covered, so leaving any of them in
# the sum would raise the Total - which is exactly how the real report overstated itself.
FILTERED = [
    "| script/Deploy.s.sol     | 100.00% (60/60)  | 100.00% (30/30)  | 100.00% (8/8)  | 100.00% (6/6)    |",
    "| script/verify/Once.sol  | 100.00% (40/40)  | 100.00% (20/20)  | 100.00% (4/4)  | 100.00% (4/4)    |",
    "| src/../script/Dupe.sol  | 100.00% (30/30)  | 100.00% (15/15)  | 100.00% (4/4)  | 100.00% (2/2)    |",
]

# forge's own Total, spanning every row above whether the report keeps it or not. Deliberately wrong for
# each case below, so a Total that merely echoes it cannot pass.
FORGE_TOTAL = "| Total                   | 96.43% (145/150) | 92.00% (72/85)   | 79.17% (19/24) | 93.75% (15/16)   |"

HEADER = [
    "| File                    | % Lines          | % Statements     | % Branches     | % Funcs          |",
    "|-------------------------|------------------|------------------|----------------|------------------|",
]


def table(kept: list[str]) -> str:
    return "\n".join(HEADER + kept + FILTERED + [FORGE_TOTAL])


# A row whose branch and statement columns have nothing to measure. Recent forge reports these as
# "N/A (0/0)"; older versions reported "100.00% (0/0)".
NOTHING_TO_MEASURE = (
    "| src/NoBranches.sol      | 50.00% (10/20)   | N/A (0/0)        | N/A (0/0)      | 100.00% (2/2)    |"
)


def counts(cell: str) -> tuple[int, int]:
    match = re.search(r"\((\d+)/(\d+)\)", cell)
    assert match is not None, f"no (covered/measured) counts in {cell!r}"
    return int(match.group(1)), int(match.group(2))


def extract(kept: list[str]):
    result = load_module().toNamedDataFrame(table(kept))
    assert result is not None
    df, _ = result
    rows = df.values.tolist()
    reported = [row for row in rows if row[0] != "Total"]
    totals = [row for row in rows if row[0] == "Total"]
    assert len(totals) == 1, "exactly one Total row"
    return df, reported, totals[0]


@pytest.mark.parametrize(
    "kept_count",
    [0, 1, 2],
    ids=["no reported rows", "one reported row", "several reported rows"],
)
def test_total_sums_exactly_the_rows_the_report_keeps(kept_count: int):
    """The Total adds up the rows shown, at every size the sum can take.

    forge's Total spans files the extractor filters out, so it both overstates coverage and moves when a
    file absent from the report changes - failing the regression diff while every visible row is
    identical. Summing the kept rows is the only Total that means anything under the table it sits on.

    Sizes matter here because the sum is a loop: none reported (everything filtered), exactly one - where
    a Total that simply echoed its single row would also pass - and several, where it must actually add.
    """
    df, reported, total = extract(KEPT[:kept_count])

    assert [row[0] for row in reported] == [row.split("|")[1].strip() for row in KEPT[:kept_count]], (
        "filtering kept the wrong rows"
    )

    for column in range(1, len(df.columns)):
        covered = sum(counts(row[column])[0] for row in reported)
        measured = sum(counts(row[column])[1] for row in reported)
        assert counts(total[column]) == (covered, measured), (
            f"{df.columns[column]}: Total says {total[column]}, rows sum to ({covered}/{measured})"
        )


def test_a_lone_reported_row_is_not_inflated_by_the_filtered_ones():
    """The single-row case pinned against its concrete wrong answer.

    With one row kept and three fully-covered rows dropped, a Total carrying the dropped rows reads
    145/150; the row it sits under holds 10/20. Naming the wrong value is what stops the check being
    satisfied by any plausible-looking number.
    """
    _, reported, total = extract(KEPT[:1])

    assert counts(reported[0][1]) == (10, 20)
    assert counts(total[1]) != (145, 150), "the Total is forge's, not the report's"
    assert counts(total[1]) == (10, 20)


def test_a_column_with_nothing_to_measure_reads_as_not_applicable():
    """A "N/A (0/0)" column keeps forge's not-applicable reading instead of being passed through raw.

    A file with no branches has neither covered nor uncovered ones, so it must not be marked as a
    shortfall, and it must not claim full coverage either - the ✓ that "100.00% (0/0)" used to produce
    said a file was fully covered when nothing about it was measured at all. It carries its own
    marker, laid out to the width of the ✓/X forms so the markers stay in one column.
    """
    _, reported, _ = extract([NOTHING_TO_MEASURE])

    lines, statements, branches, functions = reported[0][1:5]
    assert statements == "-  N/A (0/0)"
    assert branches == "-  N/A (0/0)"
    assert lines == "X  50% (10/20)", "the measured columns are unaffected"
    assert functions == "✓ 100% (2/2)"
    assert len(statements.split(" (")[0]) == len(functions.split(" (")[0]), "markers share one column"


def test_a_column_with_nothing_to_measure_adds_nothing_to_the_total():
    """0/0 columns leave the Total to the rows that were actually measured.

    Counting an unmeasured column as fully covered would lift the Total above what the report can
    show; counting it as uncovered would sink it. It contributes neither.
    """
    _, reported, total = extract([*KEPT[:1], NOTHING_TO_MEASURE])

    assert counts(total[2]) == counts(reported[0][2]), "the unmeasured statements column added counts"
    assert counts(total[1]) == (20, 40), "the measured lines columns sum normally"


def test_an_empty_report_totals_nothing_rather_than_forges_figure():
    """Everything filtered out: the Total must collapse to 0/0, not report 145 covered lines.

    This is the case where echoing forge is most obviously wrong - there is no row to justify any
    coverage at all - and the one a sum written without a zero-iteration guard would get wrong.
    """
    _, reported, total = extract([])

    assert reported == []
    assert counts(total[1]) == (0, 0)
    assert total[1] == "-  N/A (0/0)", "a Total over no rows is not applicable, not fully covered"
