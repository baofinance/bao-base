"""
Behaviour spec for duration-regression DETECTION, independent of how it is stored or computed.

Each scenario states a baseline run and a follow-up run in absolute per-suite CPU (the natural way to
say "this suite got 40x slower" or "the machine is twice as fast"), and asserts EXACTLY which suites
should be reported as changed. A machine speed change must flag nothing; a genuine per-suite change
must flag that suite and ONLY that suite, however much it distorts the run around it.

These are written against the target behaviour, so a share-of-total implementation FAILS the coupling
scenarios (a dominant mover drags every other suite's share past tolerance) while passing the pure
machine-change ones. That red/green split is the whole point: it is the spec the detection method has
to meet, and the evidence for choosing the method.
"""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin"
COMPARE_DURATION = BIN / "compare-duration.py"


def _load(path):
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(BIN))
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


_FORMAT = _load(BIN / "duration_format.py")
_COMPARE = _load(BIN / "compare.py")
_POLICY_HEADER = _COMPARE.header_line(_load(COMPARE_DURATION).DURATION_POLICY)


def duration_file(cpu: dict[str, float], with_header: bool) -> str:
    """A duration regression file built from absolute per-suite CPU seconds (stored as milliseconds)."""
    lines = [_POLICY_HEADER, ""] if with_header else []
    lines += [_FORMAT.SUITE_SECTION, "| name | milliseconds |", "|---|---|"]
    lines += [f"| {name} | {round(seconds * _FORMAT.MILLISECONDS_PER_SECOND)} |" for name, seconds in cpu.items()]
    return "\n".join(lines) + "\n"


def flagged_suites(baseline: dict[str, float], follow_up: dict[str, float]) -> set[str]:
    """The set of SUITES the comparison reports as changed (added / removed / changed).

    Reads the per-suite change lines the merge writes to stderr - "which suites did it point at",
    which is what every scenario asserts.
    """
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / "committed.txt").write_text(duration_file(baseline, with_header=True))
        (base / "fresh.txt").write_text(duration_file(follow_up, with_header=False))
        result = subprocess.run(
            [sys.executable, str(COMPARE_DURATION), str(base / "committed.txt"), str(base / "fresh.txt")],
            capture_output=True,
            text=True,
        )
    suites = set()
    for line in result.stderr.splitlines():
        if _FORMAT.SUITE_SECTION not in line or " :: " not in line:
            continue
        suites.add(line.split(" :: ", 1)[1].rsplit(": ", 1)[0])
    return suites


# A realistic spread: one large suite, several mid, several small, one below the noise floor. Enough
# suites that a robust scale (a median of per-suite ratios) is well defined.
BASELINE = {
    "test/A.t.sol:ATest": 20.0,
    "test/B.t.sol:BTest": 14.0,
    "test/C.t.sol:CTest": 11.0,
    "test/D.t.sol:DTest": 9.0,
    "test/E.t.sol:ETest": 7.0,
    "test/F.t.sol:FTest": 6.0,
    "test/G.t.sol:GTest": 4.0,
    "test/H.t.sol:HTest": 3.0,
    "test/I.t.sol:ITest": 2.0,
    "test/J.t.sol:JTest": 1.5,
    "test/K.t.sol:KTest": 1.0,
    "test/L.t.sol:LTest": 0.02,  # below the 0.05s floor
}


def scaled(cpu: dict[str, float], factor: float, overrides: dict[str, float] | None = None) -> dict[str, float]:
    """Every suite multiplied by `factor` (a machine-speed change), with named suites multiplied more."""
    overrides = overrides or {}
    return {name: seconds * factor * overrides.get(name, 1.0) for name, seconds in cpu.items()}


# ── machine-speed changes must flag NOTHING, however extreme ──────────────────


def test_a_2x_faster_machine_flags_nothing():
    assert flagged_suites(BASELINE, scaled(BASELINE, 0.5)) == set()


def test_a_10x_faster_machine_flags_nothing():
    # Everything an order of magnitude faster is still just a faster machine - no test changed.
    assert flagged_suites(BASELINE, scaled(BASELINE, 0.1)) == set()


def test_a_3x_slower_machine_flags_nothing():
    assert flagged_suites(BASELINE, scaled(BASELINE, 3.0)) == set()


# A run dominated by one suite (the shape a gas run takes under --isolate: the StabilityPoolEnvelope
# suites were ~85% of it). Collapsing the dominant suite here is the maxUsers case that started this.
DOMINATED = {
    "test/Stress.t.sol:StressTest": 200.0,  # ~85% of the run
    "test/M.t.sol:MTest": 8.0,
    "test/N.t.sol:NTest": 6.0,
    "test/O.t.sol:OTest": 5.0,
    "test/P.t.sol:PTest": 4.0,
    "test/Q.t.sol:QTest": 3.5,
    "test/R.t.sol:RTest": 3.0,
    "test/S.t.sol:STest": 2.5,
    "test/T.t.sol:TTest": 2.0,
    "test/U.t.sol:UTest": 1.5,
}


# ── one genuine change flags that suite and ONLY that suite ───────────────────


def test_one_dominant_regression_flags_only_itself():
    # The largest suite 40x - it swamps the run, so every other suite's share of the total collapses.
    # Only A actually changed; a share-of-total method flags the whole innocent field around it.
    follow_up = scaled(BASELINE, 1.0, {"test/A.t.sol:ATest": 40.0})
    assert flagged_suites(BASELINE, follow_up) == {"test/A.t.sol:ATest"}


def test_a_dominant_suite_collapsing_flags_only_itself():
    # The maxUsers case: the suite that IS most of the run becomes trivial (a stress test disabled).
    # Its disappearance lifts every survivor's share past tolerance. Only Stress changed.
    follow_up = scaled(DOMINATED, 1.0, {"test/Stress.t.sol:StressTest": 0.02})
    assert flagged_suites(DOMINATED, follow_up) == {"test/Stress.t.sol:StressTest"}


def test_a_regression_hidden_under_a_2x_faster_machine():
    # The machine is twice as fast AND one suite regressed 40x algorithmically. Its absolute time is
    # still up (0.5 x 40 = 20x), and it must be caught despite everything around it being faster.
    follow_up = scaled(BASELINE, 0.5, {"test/C.t.sol:CTest": 40.0})
    assert flagged_suites(BASELINE, follow_up) == {"test/C.t.sol:CTest"}


def test_two_regressions_with_a_2x_slower_machine():
    # Two independent regressions plus a machine change at once: both movers, nothing else.
    follow_up = scaled(BASELINE, 2.0, {"test/A.t.sol:ATest": 40.0, "test/E.t.sol:ETest": 40.0})
    assert flagged_suites(BASELINE, follow_up) == {"test/A.t.sol:ATest", "test/E.t.sol:ETest"}


def test_a_moderate_collapse_does_not_cascade():
    # The asymmetry worth pinning: a regression cascades because the mover GROWS to dominate the run,
    # but a MODERATE collapse does not - the largest suite here is only a quarter of the run, so
    # halving the total's worst case still leaves every survivor's share within tolerance. Only A.
    follow_up = scaled(BASELINE, 1.0, {"test/A.t.sol:ATest": 0.01})
    assert flagged_suites(BASELINE, follow_up) == {"test/A.t.sol:ATest"}


def test_sub_floor_noise_stays_silent():
    # A suite that is below the floor and stays there (0.02s -> 0.045s) is unmeasurable noise whatever
    # its relative jump, so it must never flag. (A suite that CROSSED the floor to seconds of real work
    # is a genuine change and is covered elsewhere - this is only the stays-tiny case.)
    follow_up = scaled(BASELINE, 1.0, {"test/L.t.sol:LTest": 2.25})
    assert flagged_suites(BASELINE, follow_up) == set()
