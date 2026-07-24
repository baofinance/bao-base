"""
Tests for bin/compare-duration.py - per-suite CPU compared by median-of-ratios.

The end-to-end detection behaviour (a machine change flags nothing; one suite going 40x flags only
itself, however much it distorts the run around it) is the spec in test_duration_scenarios.py. This
file pins the internals that produce it: the robust scale, the per-suite hold/flag decision, the
floor, the file format, and the honest notes about what the method cannot do.
"""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin"
COMPARE_DURATION = BIN / "compare-duration.py"
MILLISECONDS_PER_SECOND = 1000


def load_module():
    sys.path.insert(0, str(BIN))
    spec = importlib.util.spec_from_file_location("compare_duration", COMPARE_DURATION)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


MODULE = load_module()
FLOOR_MS = MODULE.DURATION_POLICY["floor_seconds"] * MILLISECONDS_PER_SECOND


def _policy_header() -> str:
    sys.path.insert(0, str(BIN))
    import compare  # noqa: E402

    return compare.header_line(MODULE.DURATION_POLICY)


def duration_file(name_to_seconds: dict, with_header: bool) -> str:
    """A duration file from absolute per-suite CPU seconds (stored as milliseconds)."""
    lines = [_policy_header(), ""] if with_header else []
    lines += [MODULE.SUITE_SECTION, "| name | milliseconds |", "|---|---|"]
    lines += [f"| {name} | {round(seconds * MILLISECONDS_PER_SECOND)} |" for name, seconds in name_to_seconds.items()]
    return "\n".join(lines) + "\n"


def run_merge(committed: dict, fresh: dict) -> tuple[int, dict, str]:
    """Run compare-duration on two runs (per-suite seconds); return (rc, merged milliseconds, stderr)."""
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / "committed.txt").write_text(duration_file(committed, with_header=True))
        (base / "fresh.txt").write_text(duration_file(fresh, with_header=False))
        result = subprocess.run(
            [sys.executable, str(COMPARE_DURATION), str(base / "committed.txt"), str(base / "fresh.txt")],
            capture_output=True,
            text=True,
        )
    merged = {}
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith("| test/"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        merged[cells[0]] = int(cells[1])
    return result.returncode, merged, result.stderr


# ── the robust scale: the median of per-suite ratios, ignoring sub-floor suites ──


def test_machine_scale_is_the_median_of_ratios():
    # A few suites doubled, most unchanged: the median ratio is the machine factor (1.0), not dragged
    # by the movers. This is what decouples the per-suite verdict from the run around it.
    committed = {f"test/{c}.t.sol:X": 10_000 for c in "ABCDEFG"}
    fresh = dict(committed, **{"test/A.t.sol:X": 20_000, "test/B.t.sol:X": 30_000})
    scale, measurable = MODULE.machine_scale(committed, fresh, FLOOR_MS)
    assert scale == 1.0
    assert measurable == 7


def test_scale_recovers_a_uniform_machine_change():
    committed = {f"test/{c}.t.sol:X": 10_000 for c in "ABCDE"}
    fresh = {name: value * 2 for name, value in committed.items()}
    scale, _ = MODULE.machine_scale(committed, fresh, FLOOR_MS)
    assert scale == 2.0


def test_scale_ignores_sub_floor_suites():
    # A suite below the floor in either run is unmeasurable; a ratio taken against noise is meaningless
    # and must not enter the median.
    committed = {"test/A.t.sol:X": 10_000, "test/tiny.t.sol:X": 10}  # tiny is 10ms < 50ms floor
    fresh = {"test/A.t.sol:X": 10_000, "test/tiny.t.sol:X": 5_000}  # tiny exploded, but was sub-floor
    _, measurable = MODULE.machine_scale(committed, fresh, FLOOR_MS)
    assert measurable == 1  # only A counted


# ── the per-suite hold / flag decision ──────────────────────────────────────


def test_a_suite_tracking_the_scale_is_held_at_its_committed_value():
    # Held suites keep their COMMITTED milliseconds, so the file is byte-stable run to run - only a
    # genuine change rewrites a row. A 2x machine with a suite that also merely doubled: held.
    rc, merged, _ = run_merge(
        {"test/A.t.sol:X": 10.0, "test/B.t.sol:X": 10.0}, {"test/A.t.sol:X": 20.0, "test/B.t.sol:X": 20.0}
    )
    assert rc == 0
    assert merged["test/A.t.sol:X"] == 10_000  # committed value kept, not the fresh 20_000


def test_a_suite_deviating_from_the_scale_flags_and_takes_its_fresh_value():
    # 10s -> 100s is a 10x deviation, past the coarse blow-up band; the innocents around it hold.
    rc, merged, stderr = run_merge(
        {f"test/{c}.t.sol:X": 10.0 for c in "ABCDE"},
        {**{f"test/{c}.t.sol:X": 10.0 for c in "ABCDE"}, "test/A.t.sol:X": 100.0},
    )
    assert rc == 1
    assert merged["test/A.t.sol:X"] == 100_000
    assert "test/A.t.sol:X" in stderr
    assert "test/B.t.sol:X" not in stderr  # no cascade onto the innocents


def test_a_noise_sized_change_on_a_small_suite_is_held():
    # Relative comparison is unreliable at small magnitudes: a tiny overhead-dominated suite (a
    # `_sizes` contract-size test) is pure framework noise, swinging as much as its own magnitude
    # between runs. Reproduces the real bao-base coverage churn - TestHarborFixedOwnableOnly measured
    # 1.10s then 0.28s, an 0.82s swing that is scheduler noise, not a regression. The noise floor holds
    # it (a change under 1.5s never flags however large its ratio), while any "40x" on a suite that
    # matters is seconds of change and still flags.
    committed = {f"test/{c}.t.sol:X": 10.0 for c in "ABCDE"}
    fresh = dict(committed)
    committed["test/_sizes/small.t.sol:X"] = 1.10
    fresh["test/_sizes/small.t.sol:X"] = 0.28
    rc, merged, _ = run_merge(committed, fresh)
    assert rc == 0
    assert merged["test/_sizes/small.t.sol:X"] == 1100  # held at committed 1100ms, not the fresh 280ms


def test_a_new_suite_flags_as_added():
    rc, _, stderr = run_merge({"test/A.t.sol:X": 10.0}, {"test/A.t.sol:X": 10.0, "test/New.t.sol:X": 5.0})
    assert rc == 1
    assert "added" in stderr and "test/New.t.sol:X" in stderr


def test_a_removed_suite_flags():
    rc, merged, stderr = run_merge({"test/A.t.sol:X": 10.0, "test/Gone.t.sol:X": 5.0}, {"test/A.t.sol:X": 10.0})
    assert rc == 1
    assert "removed" in stderr and "test/Gone.t.sol:X" in stderr
    assert "test/Gone.t.sol:X" not in merged  # dropped from the baseline


def test_both_below_floor_is_held_however_large_the_relative_jump():
    # A suite that is noise in both runs (30ms -> 45ms, both under the 50ms floor) never flags.
    rc, merged, _ = run_merge(
        {"test/A.t.sol:X": 10.0, "test/tiny.t.sol:X": 0.03}, {"test/A.t.sol:X": 10.0, "test/tiny.t.sol:X": 0.045}
    )
    assert rc == 0
    assert merged["test/tiny.t.sol:X"] == 30  # held at committed 30ms


def test_a_suite_crossing_the_floor_upward_flags():
    # Below the floor in the baseline (30ms) but seconds of real work now: a genuine new cost.
    rc, _, stderr = run_merge(
        {"test/A.t.sol:X": 10.0, "test/riser.t.sol:X": 0.03}, {"test/A.t.sol:X": 10.0, "test/riser.t.sol:X": 5.0}
    )
    assert rc == 1
    assert "test/riser.t.sol:X" in stderr


# ── the file the comparison writes ──────────────────────────────────────────


def test_display_shows_milliseconds_then_seconds():
    _, _, _ = run_merge({"test/A.t.sol:X": 20.0}, {"test/A.t.sol:X": 20.0})
    text = duration_file({"test/A.t.sol:X": 20.0}, with_header=True)
    row = next(line for line in text.splitlines() if line.strip().startswith("| test/"))
    cells = [c.strip() for c in row.strip("|").split("|")]
    assert cells[1] == "20000"  # the stored, compared value


def test_display_precision_follows_the_floor():
    import duration_format  # noqa: E402

    assert duration_format.seconds_decimals(0.5) == 1
    assert duration_format.seconds_decimals(0.05) == 2
    assert duration_format.seconds_decimals(5.0) == 0


# ── honest notes about what the method cannot do ────────────────────────────


def test_a_large_uniform_shift_is_reported_but_never_flags():
    # A 5x slower machine (or environment) is indistinguishable from everything being 5x slower, so it
    # must not flag a single suite - only note the whole-run shift for a human to judge.
    rc, _, stderr = run_merge(
        {f"test/{c}.t.sol:X": 10.0 for c in "ABCDE"}, {f"test/{c}.t.sol:X": 50.0 for c in "ABCDE"}
    )
    assert rc == 0
    assert "whole run is 5.00x" in stderr


def test_too_few_measurable_suites_is_reported():
    # Only one suite above the floor: the median scale rests on too few suites to trust (a couple of
    # changes could swing it), and the run says so rather than passing quietly.
    below = {f"test/tiny{i}.t.sol:X": 0.01 for i in range(6)}
    rc, _, stderr = run_merge({"test/A.t.sol:X": 10.0, **below}, {"test/A.t.sol:X": 10.0, **below})
    assert "may be unreliable" in stderr


def test_enough_measurable_suites_gives_no_unreliable_note():
    # A median over a dozen suites is robust; the note must NOT fire just because many tiny suites sit
    # below the floor. This is the small-project shape - bao-base coverage has ~13 measurable of ~53,
    # plenty for the scale - and it must not be told its scale is unreliable when it is fine.
    measurable = {f"test/M{i}.t.sol:X": 10.0 for i in range(8)}
    below = {f"test/tiny{i}.t.sol:X": 0.01 for i in range(20)}
    _, _, stderr = run_merge({**measurable, **below}, {**measurable, **below})
    assert "unreliable" not in stderr


def test_no_suites_is_a_no_op():
    # A build with no test suites (forge build --sizes) measures no durations: nothing to compare.
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / "committed.txt").write_text("")
        (base / "fresh.txt").write_text("")
        result = subprocess.run(
            [sys.executable, str(COMPARE_DURATION), str(base / "committed.txt"), str(base / "fresh.txt")],
            capture_output=True,
            text=True,
        )
    assert result.returncode == 0
