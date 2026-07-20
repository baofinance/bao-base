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

STUB_LOG = """\
Ran 1 test for test/A.t.sol:ATest
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 2.00s (1.00s CPU time)
Ran 2 tests for test/B.t.sol:BTest
Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 6.00s (3.00s CPU time)
"""


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
