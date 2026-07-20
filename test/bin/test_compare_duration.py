"""
Tests for the duration regression policy (bin/compare-duration.py).

Duration is compared at two granularities because neither alone is sufficient:
  - per suite, its SHARE of run CPU — machine-independent, catches a suite that got worse relative
    to its peers;
  - per run, the TOTAL CPU in seconds — the only thing that moves when a change slows every suite
    equally, which leaves every share exactly where it was.
Tolerances are symmetric (no ratchet: a small improvement is held, not locked in) and hold when
within EITHER bound, so the absolute bound acts as a noise floor for suites too small to measure.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

COMPARE_DURATION = Path(__file__).resolve().parents[2] / "bin" / "compare-duration.py"

# A run of 1000s CPU split across five suites; shares are parts per billion and sum to 1e9.
# Absolute CPU per suite is share/1e9 * the total: A=500s B=300s C=150s D=49.98s E=20ms.
# E sits below the noise floor; the rest are far above it. The total is in MILLISECONDS, so that a
# small run (bao-base's whole suite is ~1s) keeps enough resolution to be compared at all.
BASE_SHARES = {
    "test/A.t.sol:ATest": 500_000_000,
    "test/B.t.sol:BTest": 300_000_000,
    "test/C.t.sol:CTest": 150_000_000,
    "test/D.t.sol:DTest": 49_980_000,
    "test/E.t.sol:ETest": 20_000,
}
BASE_TOTAL = 1_000_000  # milliseconds = 1000s


def duration_file(shares: dict[str, int], total: int, header: str | None) -> str:
    """Build a duration regression file; `header` None makes it a fresh extract (no header line)."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("compare_duration", COMPARE_DURATION)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    lines = [header, ""] if header is not None else []
    lines += [module.SHARE_SECTION, "| name | share |", "|---|---|"]
    lines += [f"| {name} | {value} |" for name, value in shares.items()]
    lines += ["", module.TOTAL_SECTION, "| name | milliseconds |", "|---|---|", f"| all suites | {total} |"]
    return "\n".join(lines) + "\n"


def committed_header() -> str:
    """The header this policy emits — rendered by the SHARED renderer, as every type's is."""
    import importlib.util
    import sys as _sys

    _sys.path.insert(0, str(COMPARE_DURATION.parent))
    import compare  # noqa: E402

    spec = importlib.util.spec_from_file_location("compare_duration", COMPARE_DURATION)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return compare.header_line(module.DURATION_POLICY)


def run_merge(committed_text: str, fresh_text: str) -> tuple[int, dict[str, int], str]:
    """Run compare-duration.py on two temp files; return (returncode, merged values, stderr)."""
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / "committed.txt").write_text(committed_text)
        (base / "fresh.txt").write_text(fresh_text)
        result = subprocess.run(
            [sys.executable, str(COMPARE_DURATION), str(base / "committed.txt"), str(base / "fresh.txt")],
            capture_output=True,
            text=True,
        )
    values = {}
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) < 2 or cells[0].lower() == "name" or set(cells[0]) <= set("-: "):
            continue
        values[cells[0]] = int(float(cells[1]))
    return result.returncode, values, result.stderr


def merge_against_base(shares: dict[str, int], total: int) -> tuple[int, dict[str, int], str]:
    """Compare a fresh run against the unchanged BASE baseline."""
    return run_merge(
        duration_file(BASE_SHARES, BASE_TOTAL, committed_header()),
        duration_file(shares, total, None),
    )


def test_single_suite_slowdown_flags():
    # One suite tripling its share of the run is the headline case: its peers are unmoved, so the
    # share check is what has to catch it.
    shares = dict(BASE_SHARES, **{"test/C.t.sol:CTest": 450_000_000})
    rc, values, err = merge_against_base(shares, BASE_TOTAL)
    assert rc == 1
    assert values["test/C.t.sol:CTest"] == 450_000_000
    assert "test/C.t.sol:CTest" in err


def test_uniform_slowdown_flags_via_total():
    # Every suite slowed by the same factor leaves EVERY share identical — this is the case an
    # "and" of share-and-absolute would miss entirely, and it is why the run total is checked.
    rc, values, err = merge_against_base(BASE_SHARES, BASE_TOTAL * 40)
    assert rc == 1
    assert values["all suites"] == BASE_TOTAL * 40
    assert "all suites" in err


def test_machine_change_does_not_flag():
    # A uniformly slower machine moves the total but not the shares; within the total's tolerance
    # that must stay silent, or the check fires on every machine it did not record the baseline on.
    rc, values, err = merge_against_base(BASE_SHARES, BASE_TOTAL * 2)
    assert rc == 0
    assert values["all suites"] == BASE_TOTAL  # held at the committed value, no churn
    assert err == ""


def test_tiny_suite_noise_does_not_flag():
    # E is 20ms of a 1000s run. Doubling it is scheduler jitter, not a regression, and the absolute
    # bound must hold it despite the relative change being large.
    shares = dict(BASE_SHARES, **{"test/E.t.sol:ETest": 40_000})
    rc, values, _ = merge_against_base(shares, BASE_TOTAL)
    assert rc == 0
    assert values["test/E.t.sol:ETest"] == 20_000


def test_a_one_second_run_can_still_flag():
    # bao-base's whole suite takes about a second. A floor of half a second over a run that short is
    # half the run, so no row could ever exceed it however much it grew and the check passed
    # unconditionally. The floor has to be small enough to leave room at this scale.
    one_second = 1_000  # milliseconds
    committed = duration_file(
        {"test/A.t.sol:ATest": 250_000_000, "test/B.t.sol:BTest": 750_000_000}, one_second, committed_header()
    )
    grown = duration_file({"test/A.t.sol:ATest": 600_000_000, "test/B.t.sol:BTest": 400_000_000}, one_second, None)
    rc, _, err = run_merge(committed, grown)
    assert rc == 1
    assert "test/A.t.sol:ATest" in err  # a quarter of the run growing to well over half


def test_a_run_too_small_to_measure_says_so():
    # When most suites fall under the floor the check is largely inert, and that must be visible
    # rather than reported as a clean pass - a silent vacuous check is worse than no check.
    tiny_total = 200  # milliseconds: every suite below is a few tens of ms
    shares = {f"test/{letter}.t.sol:{letter}Test": 250_000_000 for letter in "ABCD"}
    rc, _, err = run_merge(
        duration_file(shares, tiny_total, committed_header()), duration_file(shares, tiny_total, None)
    )
    assert rc == 0  # nothing changed, so it still passes
    assert "below the" in err and "floor" in err
    assert "4" in err  # names how many of the suites cannot flag


def test_modest_suite_deletion_does_not_flag_survivors():
    # Deleting D (~5% of the run) inflates every survivor's share by ~5%; only the removal itself
    # should be reported.
    shares = {name: value for name, value in BASE_SHARES.items() if "D.t.sol" not in name}
    grown = {name: round(value * 1e9 / sum(shares.values())) for name, value in shares.items()}
    rc, values, err = merge_against_base(grown, BASE_TOTAL)
    assert rc == 1
    assert "test/D.t.sol:DTest" in err
    assert values["test/A.t.sol:ATest"] == BASE_SHARES["test/A.t.sol:ATest"]  # survivor held
    assert values["test/B.t.sol:BTest"] == BASE_SHARES["test/B.t.sol:BTest"]


def test_new_suite_flags_once_then_holds():
    # A new suite has no baseline to compare against, so it is flagged; once its value is recorded
    # the next run holds it.
    shares = dict(BASE_SHARES, **{"test/F.t.sol:FTest": 1_000_000})
    rc, _, err = merge_against_base(shares, BASE_TOTAL)
    assert rc == 1
    assert "test/F.t.sol:FTest" in err
    recorded = run_merge(
        duration_file(shares, BASE_TOTAL, committed_header()),
        duration_file(shares, BASE_TOTAL, None),
    )
    assert recorded[0] == 0


def merged_output(shares: dict[str, int], total: int) -> str:
    """The rendered merged file for a run compared against itself (so every row is held)."""
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / "committed.txt").write_text(duration_file(shares, total, committed_header()))
        (base / "fresh.txt").write_text(duration_file(shares, total, None))
        return subprocess.run(
            [sys.executable, str(COMPARE_DURATION), str(base / "committed.txt"), str(base / "fresh.txt")],
            capture_output=True,
            text=True,
        ).stdout


def merged_row(stdout: str, name: str) -> list[str]:
    """The rendered cells of one row, so the informational columns can be read back."""
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(f"| {name} ") or stripped.startswith(f"| {name}|"):
            return [cell.strip() for cell in stripped.strip("|").split("|")]
    raise AssertionError(f"{name!r} not in the merged output")


def test_display_shows_seconds_and_percent():
    # The stored value is a share in parts per billion, which is unreadable on its own. Both derived
    # columns come from data already in the file (share and total), so nothing extra is recorded.
    stdout = merged_output(BASE_SHARES, BASE_TOTAL)
    cells = merged_row(stdout, "test/A.t.sol:ATest")
    assert cells[1] == "500000000"  # the comparison value stays in column 2, where the merge reads it
    assert cells[2] == "500.00s"  # 50% of a 1000s run, at the precision the 0.05s floor justifies
    assert cells[3] == "50.00%"


def test_rows_are_sorted_by_name():
    # Forge emits suites in completion order, which varies run to run under parallel execution. A
    # stable order is what makes a side-by-side diff of two baselines readable, so the input here is
    # deliberately NOT already in name order.
    scrambled = {
        "test/Z.t.sol:ZTest": 500_000_000,
        "test/M.t.sol:MTest": 300_000_000,
        "test/A.t.sol:ATest": 200_000_000,
    }
    stdout = merged_output(scrambled, BASE_TOTAL)
    names = [
        line.strip().strip("|").split("|")[0].strip()
        for line in stdout.splitlines()
        if line.strip().startswith("| test/")
    ]
    assert names == ["test/A.t.sol:ATest", "test/M.t.sol:MTest", "test/Z.t.sol:ZTest"]
    assert names != list(scrambled)  # the input order really was different


def test_rank_identifies_the_biggest_consumer():
    # Sorting by name hides which suites actually cost the most, so the rank carries that: 1 is the
    # largest share of the run, which is what a targeting decision needs.
    stdout = merged_output(BASE_SHARES, BASE_TOTAL)
    ranks = {merged_row(stdout, name)[0]: merged_row(stdout, name)[-1] for name in BASE_SHARES}
    assert ranks["test/A.t.sol:ATest"] == "1"  # 50% of the run
    assert ranks["test/B.t.sol:BTest"] == "2"  # 30%
    assert ranks["test/E.t.sol:ETest"] == "5"  # 20ms, the smallest


def test_display_precision_follows_the_floor():
    # Showing more digits than the tolerance can act on is noise: a 0.05s floor means two decimals
    # in seconds. The precision is derived from the floor constant, so changing one moves the other.
    import importlib.util

    spec = importlib.util.spec_from_file_location("compare_duration", COMPARE_DURATION)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    assert module.seconds_decimals(0.5) == 1
    assert module.seconds_decimals(0.05) == 2
    assert module.seconds_decimals(5.0) == 0


def test_no_ratchet_a_small_improvement_is_held():
    # Gas ratchets: ANY improvement is locked in, keeping the baseline at the best value ever seen.
    # For duration that would anchor every suite at its fastest run on an idle machine, so a small
    # improvement must be held like any other within-tolerance change.
    shares = dict(BASE_SHARES, **{"test/C.t.sol:CTest": 149_000_000})
    rc, values, _ = merge_against_base(shares, BASE_TOTAL)
    assert rc == 0
    assert values["test/C.t.sol:CTest"] == 150_000_000
