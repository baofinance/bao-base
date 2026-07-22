"""
Tests for bin/duration-of.py — the wrapper that records how long a run's test suites took.

Duration is orthogonal to what a run measures, so this decorates any run rather than living inside
`regression-of`: `duration-of test` covers the plain test run, `duration-of regression-of gas` the
gas run, and `sizes` is simply not wrapped (a build has no suites).

The wrapper runs its inner command as a SUBPROCESS. That is load-bearing: `regression-of` calls
`error` — which is `exit 1` — as a NORMAL outcome whenever a regression file changes, and `run`
dispatches bash scripts by SOURCING them, so a sourcing wrapper would be killed by its own inner
command and lose the timings exactly when a regression occurred.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

DURATION_OF = pathlib.Path(__file__).resolve().parents[2] / "bin" / "duration-of.py"

def _log(cpu_seconds: dict[str, float]) -> str:
    """A forge test log reporting the given per-suite CPU seconds (wall is twice CPU, arbitrarily)."""
    lines = []
    for name, cpu in cpu_seconds.items():
        lines.append(f"Ran 1 test for {name}")
        lines.append(f"Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in {cpu * 2:.2f}s ({cpu:.2f}s CPU time)")
    return "\n".join(lines) + "\n"


# Enough suites that the median-of-ratios scale is stable; A and B are asserted by name below.
BASELINE_CPU = {
    "test/A.t.sol:ATest": 1.0,
    "test/B.t.sol:BTest": 3.0,
    "test/C.t.sol:CTest": 2.0,
    "test/D.t.sol:DTest": 4.0,
    "test/E.t.sol:ETest": 5.0,
}
STUB_LOG = _log(BASELINE_CPU)


def load_module():
    spec = importlib.util.spec_from_file_location("duration_of", DURATION_OF)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def run_wrapper(directory: pathlib.Path, exit_code: int, *args: str) -> subprocess.CompletedProcess:
    """Run duration-of against a stub `run` that prints a canned log and exits with `exit_code`.

    Pointing BAO_BASE_DIR at the stub is the same seam production uses — the wrapper invokes
    "$BAO_BASE_DIR/run" either way — so this exercises the real dispatch path.
    """
    stub = directory / "run"
    stub.write_text(f'#!/usr/bin/env bash\ncat <<\'LOG\'\n{STUB_LOG}LOG\nexit {exit_code}\n')
    stub.chmod(0o755)
    environment = dict(os.environ, BAO_BASE_DIR=str(directory))
    return subprocess.run(
        [sys.executable, str(DURATION_OF), *args],
        cwd=directory,
        env=environment,
        capture_output=True,
        text=True,
    )


def test_name_deduced_from_command():
    # The measure is named after the run, taken as the last positional before the first flag: the
    # trailing argument is not usable because pass-through flags carry their own values.
    measure_name = load_module().measure_name
    assert measure_name(["test"]) == "test"
    assert measure_name(["regression-of", "gas"]) == "gas"
    assert measure_name(["regression-of", "gas", "--no-match-contract", "RangeIntegral"]) == "gas"
    assert measure_name(["test", "--match-path", "test/Foo.t.sol"]) == "test"


def test_inner_exit_code_propagated():
    # A failing run matters more than a duration change, so its exit code is the one that survives.
    with tempfile.TemporaryDirectory() as directory:
        result = run_wrapper(pathlib.Path(directory), 3, "test")
        assert result.returncode == 3


def test_timings_extracted_when_inner_exits_nonzero():
    # The hazard this wrapper exists to avoid: the timings must survive an inner command that exits
    # non-zero, because that is precisely when a regression is being reported.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        run_wrapper(base, 3, "test")
        recorded = base / "regression" / "test-duration.txt"
        assert recorded.exists()
        assert "test/A.t.sol:ATest" in recorded.read_text()
        assert "test/B.t.sol:BTest" in recorded.read_text()


def test_inner_output_is_passed_through():
    # Wrapping a run must not swallow its output — the log is what the developer is reading.
    with tempfile.TemporaryDirectory() as directory:
        result = run_wrapper(pathlib.Path(directory), 0, "test")
        assert "Ran 1 test for test/A.t.sol:ATest" in result.stdout


def test_no_stray_log_left_behind():
    # The captured log is scratch: only the regression file itself should remain.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        run_wrapper(base, 0, "test")
        assert sorted(p.name for p in (base / "regression").iterdir()) == ["test-duration.txt"]


def _git(directory: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=directory, check=True, capture_output=True)


def _init_repo(base: pathlib.Path) -> None:
    _git(base, "init", "-q")
    _git(base, "config", "user.email", "t@t")
    _git(base, "config", "user.name", "t")


def test_no_change_preserves_an_uncommitted_edit():
    # A run that holds against the committed baseline must leave the working-tree file untouched. The
    # baseline is read from the git index, so an uncommitted edit to the working copy is invisible to
    # the comparison; a no-change run must not overwrite it with identical merged content (which would
    # silently discard the edit). This pins both "write only on change" and the reason for it.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        recorded = base / "regression" / "test-duration.txt"

        # First run establishes the baseline: every row is new, so it is a change and is written.
        run_wrapper(base, 0, "test")
        assert recorded.exists()
        _git(base, "add", "regression/test-duration.txt")
        _git(base, "commit", "-q", "-m", "baseline")

        # An uncommitted working-tree edit. Only the index is the baseline, so this does not change
        # what the next run compares against.
        recorded.write_text(recorded.read_text() + "# uncommitted edit\n")

        # An identical run holds against the committed baseline -> no change -> nothing written.
        result = run_wrapper(base, 0, "test")
        assert result.returncode == 0
        assert "# uncommitted edit" in recorded.read_text()


def test_change_is_written_against_a_committed_baseline():
    # The other side of the guard: when the run does breach the tolerance, the merged result IS
    # written. Committing a baseline first, then regressing ONE suite 40x (the rest unchanged, so the
    # median scale stays ~1 and the machine is judged steady) drives a genuine change - unlike scaling
    # EVERY suite, which median-of-ratios correctly reads as a machine change and holds.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        recorded = base / "regression" / "test-duration.txt"

        run_wrapper(base, 0, "test")
        _git(base, "add", "regression/test-duration.txt")
        _git(base, "commit", "-q", "-m", "baseline")

        regressed_log = _log(dict(BASELINE_CPU, **{"test/A.t.sol:ATest": 40.0}))
        stub = base / "run"
        stub.write_text(f"#!/usr/bin/env bash\ncat <<'LOG'\n{regressed_log}LOG\nexit 0\n")
        stub.chmod(0o755)
        result = subprocess.run(
            [sys.executable, str(DURATION_OF), "test"],
            cwd=base,
            env=dict(os.environ, BAO_BASE_DIR=str(base)),
            capture_output=True,
            text=True,
        )
        assert result.returncode == 1  # a duration change makes the run fail until committed
        assert "40000" in recorded.read_text()  # A's regressed value (40s -> 40000ms) was written


def test_staged_deletion_of_the_baseline_fails_fast_before_the_run():
    # A staged deletion of the duration baseline is NOT silently regenerated: the wrapper resolves the
    # baseline up front and, finding it gone from the index, aborts BEFORE running the (possibly long)
    # inner command, offering the git command that restores it from HEAD. The inner run never happens.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        recorded = base / "regression" / "test-duration.txt"
        run_wrapper(base, 0, "test")
        _git(base, "add", "regression/test-duration.txt")
        _git(base, "commit", "-q", "-m", "baseline")
        recorded.unlink()
        _git(base, "add", "regression/test-duration.txt")  # stage the deletion

        result = run_wrapper(base, 0, "test")
        assert result.returncode == 1
        assert "git restore --staged --worktree regression/test-duration.txt" in result.stderr
        assert "Ran 1 test" not in result.stdout  # fail-fast: the inner run never ran


def test_working_copy_deletion_of_the_baseline_fails_fast():
    # Only the working copy is gone (the index still holds it): the offer is a plain `git restore`,
    # which reads it back from the index. Again the run is aborted before it starts.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        recorded = base / "regression" / "test-duration.txt"
        run_wrapper(base, 0, "test")
        _git(base, "add", "regression/test-duration.txt")
        _git(base, "commit", "-q", "-m", "baseline")
        recorded.unlink()  # delete the working copy only; the index still has it

        result = run_wrapper(base, 0, "test")
        assert result.returncode == 1
        assert "git restore regression/test-duration.txt" in result.stderr
        assert "--staged" not in result.stderr
        assert "Ran 1 test" not in result.stdout
