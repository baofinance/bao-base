"""
Tests for bin/extract-duration.py — per-suite CPU time out of any forge test log.

The extract emits one absolute figure per suite: its CPU in milliseconds. Nothing is normalised
against the run total - the comparison (compare-duration.py) divides out a robust per-run scale at
compare time, which is what keeps it machine-independent without coupling every suite to every other.
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
    # rather than failing.
    module = load_module()
    assert module.parse_suites("Compiling 300 files with Solc 0.8.30\n") == []
    assert module.render([]) == ""


def test_render_stores_each_suite_in_milliseconds():
    # The stored (compared) value is the suite's absolute CPU in milliseconds - seconds x 1000,
    # rounded. Milliseconds so a run of a second or so still has resolution.
    module = load_module()
    milliseconds = _milliseconds(module.render(module.parse_suites(sample_log())))
    assert milliseconds["test/C.t.sol:CTest"] == 10_000  # 10.00s
    assert milliseconds["test/B.t.sol:BTest"] == 4  # 3.60ms -> 4ms
    assert milliseconds["test/A.t.sol:ATest"] == 0  # 147.45µs rounds to 0ms (sub-floor, held elsewhere)


def test_render_rows_are_sorted_by_name():
    # Forge emits suites in completion order; name order is what makes two baselines diffable.
    module = load_module()
    names = list(_milliseconds(module.render(module.parse_suites(sample_log()))))
    assert names == sorted(names)


def _milliseconds(rendered: str) -> dict[str, int]:
    """The suite -> milliseconds mapping (column 2) from a rendered section."""
    out: dict[str, int] = {}
    for line in rendered.splitlines():
        stripped = line.strip()
        if not stripped.startswith("| test/"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        out[cells[0]] = int(cells[1])
    return out
