"""
Tests for bin/extract-duration.py — per-suite CPU time out of any forge test log.

The extract emits two sections: each suite's share of the run's total CPU (in parts per billion, so
the value stays an integer and the baseline is machine-INDEPENDENT), and the run total in whole
seconds (machine-dependent by design — it is what catches a uniform slowdown that leaves every
share unmoved).
"""
import importlib.util
import pathlib
import textwrap

import pytest

# `147.45 * 1e-6` and the literal `147.45e-6` differ in the last bit: binary floating point holds
# neither exactly, and the two expression orders round differently. The bound is a couple of units
# in the last place (~2.2e-16 relative for a double). Reading the wall time instead of the CPU time
# — the bug these assertions exist to catch — shifts the value by tens of percent, so a tolerance
# this tight still discriminates it completely.
FLOAT_TOLERANCE = 1e-15


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "extract-duration.py"
    spec = importlib.util.spec_from_file_location("extract_duration", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def sample_log() -> str:
    """A forge test log carrying all three time units, plus lines that must NOT be read as suites."""
    return textwrap.dedent(
        """\
        Compiling 300 files with Solc 0.8.30
        Solc 0.8.30 finished in 155.04s
        Ran 1 test for test/A.t.sol:ATest
        [PASS] testOne() (gas: 100)
        Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 722.88µs (147.45µs CPU time)
        Ran 2 tests for test/B.t.sol:BTest
        [PASS] testTwo() (gas: 200)
        Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 3.93ms (3.60ms CPU time)
        Ran 3 tests for test/C.t.sol:CTest
        Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 12.00s (10.00s CPU time)
        Ran 3 test suites in 44.57s (656.25s CPU time): 837 tests passed, 0 failed
        """
    )


def test_pairs_suite_name_with_its_cpu_time():
    # The name and the timing are on different lines, so they must be paired across the gap.
    suites = load_module().parse_suites(sample_log())
    assert [name for name, _ in suites] == ["test/A.t.sol:ATest", "test/B.t.sol:BTest", "test/C.t.sol:CTest"]


def test_uses_cpu_time_not_wall_time():
    # Each result line carries wall FIRST and CPU in parentheses; reading wall would be silent and
    # plausible, and would reintroduce exactly the parallelism noise CPU time is chosen to avoid.
    suites = dict(load_module().parse_suites(sample_log()))
    assert suites["test/C.t.sol:CTest"] == pytest.approx(10.00, rel=FLOAT_TOLERANCE)  # not the 12.00s wall
    assert suites["test/B.t.sol:BTest"] == pytest.approx(3.60e-3, rel=FLOAT_TOLERANCE)  # not the 3.93ms wall


def test_parses_all_time_units():
    # Real logs carry all three: 74 lines in seconds, 61 in ms, 2 in microseconds.
    suites = dict(load_module().parse_suites(sample_log()))
    assert suites["test/A.t.sol:ATest"] == pytest.approx(147.45e-6, rel=FLOAT_TOLERANCE)
    assert suites["test/B.t.sol:BTest"] == pytest.approx(3.60e-3, rel=FLOAT_TOLERANCE)
    assert suites["test/C.t.sol:CTest"] == pytest.approx(10.00, rel=FLOAT_TOLERANCE)


def test_ignores_non_suite_timing_lines():
    # The solc compile line and the closing run summary both say "finished in"/"Ran N", and neither
    # is a suite. Three suites in the sample, not five.
    assert len(load_module().parse_suites(sample_log())) == 3


def test_empty_log_yields_empty_output():
    # `bin/sizes` runs `forge build --sizes`, which has no suites at all — that must produce no rows
    # rather than dividing by a zero total or failing.
    module = load_module()
    assert module.parse_suites("Compiling 300 files with Solc 0.8.30\n") == []
    assert module.render([]) == ""


def test_shares_sum_to_one_billion():
    # The shares are the machine-independent half of the check, so they must be a true partition of
    # the run; slack is one part per suite for the rounding to integer parts-per-billion.
    module = load_module()
    suites = module.parse_suites(sample_log())
    shares = [value for name, value in _rows(module.render(suites), "share")]
    assert abs(sum(shares) - 1_000_000_000) <= len(suites)


def test_run_total_is_the_sum_of_suite_cpu_in_milliseconds():
    # Milliseconds, so a run of a second or so still has resolution to be compared against.
    module = load_module()
    suites = module.parse_suites(sample_log())
    totals = _rows(module.render(suites), "milliseconds")
    assert len(totals) == 1
    assert totals[0][1] == round(sum(value for _, value in suites) * 1000)  # 10.0036s -> 10004ms


def _rows(rendered: str, column: str) -> list[tuple[str, int]]:
    """Rows of the section whose value column is `column`, as (name, integer value)."""
    rows: list[tuple[str, int]] = []
    in_section = False
    for line in rendered.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) < 2 or set(cells[0]) <= set("-: "):
            continue
        if cells[0].lower() == "name":
            in_section = cells[1].lower() == column
            continue
        if in_section:
            rows.append((cells[0], int(cells[1])))
    return rows
