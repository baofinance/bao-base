"""End-to-end tests for bin/regression-of.py — the wrapper that checks a run's regression metric
against the committed baseline and updates it only on a change.

`regression-of.py <type>` is run as a subprocess against a stub `run` (installed via BAO_BASE_DIR,
exactly the seam production uses) that prints a canned log for the type and exits with a chosen code.
The REAL `extract-<type>`/`compare-<type>` from bin process that log, so this exercises the true
pipeline: gas has a compare script (tolerance/ratchet); sizes has an extract script but no compare
script (exact-match fallback); a type with neither uses the raw log and exact-match.

The baseline states (present / working-copy deleted / staged deletion / never tracked) and the
"offer git, never run it" rule are covered at the unit level in test_ratchet.py; here they are checked
through the wrapper only far enough to prove it resolves up front and fails fast.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

REGRESSION_OF = pathlib.Path(__file__).resolve().parents[2] / "bin" / "regression-of.py"

# A real gas table (as `run gas` would print it); extract-gas takes the Max column.
GAS_LOG = (
    "| src/minter/Minter_v3.sol:Minter_v3 Contract |                 |        |        |        |         |\n"
    "| Function Name                                | Min             | Avg    | Median | Max    | # Calls |\n"
    "| mintPeggedToken                              | 50000           | 60000  | 55000  | 80000  | 100     |\n"
    "| collateralRatio                              | 1000            | 1200   | 1100   | 1500   | 50      |\n"
)
# The same, with mintPeggedToken's Max raised far past tolerance -> a breach the merge must flag.
GAS_LOG_REGRESSED = GAS_LOG.replace("80000  | 100", "200000 | 100")
# A Contract table with no "Function Name" header: extract-gas raises -> exits non-zero.
MALFORMED_GAS_LOG = "| src/X.sol:X Contract |  |  |  |  |  |\n| foo | 1 | 2 | 3 | 4 | 5 |\n"
# A real sizes table; sizes has an extract script but NO compare-sizes.py, so it takes the fallback.
SIZES_LOG = (
    "| Contract | Runtime Size (B) | Runtime Margin (B) | Initcode Size (B) | Initcode Margin (B) |\n"
    "| MinimalStub | 1,828 | 23 | 2,295 | 500 |\n"
    "| OzStyleStub | 4,350 | 50 | 4,454 | 600 |\n"
)


def _git(base: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=base, check=True, capture_output=True)


def _init_repo(base: pathlib.Path) -> None:
    _git(base, "init", "-q")
    _git(base, "config", "user.email", "t@t")
    _git(base, "config", "user.name", "t")


def run_regression_of(base: pathlib.Path, regression_type: str, log: str, exit_code: int = 0):
    """Run regression-of.py <type> against a stub `run` that prints `log` and exits `exit_code`.

    Pointing BAO_BASE_DIR at the stub is the seam production uses — the wrapper invokes
    "$BAO_BASE_DIR/run" either way — so the real dispatch path is exercised.
    """
    stub = base / "run"
    stub.write_text(f"#!/usr/bin/env bash\ncat <<'LOG'\n{log}LOG\nexit {exit_code}\n")
    stub.chmod(0o755)
    return subprocess.run(
        [sys.executable, str(REGRESSION_OF), regression_type],
        cwd=base,
        env=dict(os.environ, BAO_BASE_DIR=str(base)),
        capture_output=True,
        text=True,
    )


# ── gas: the compare-script (tolerance/ratchet) path ─────────────────────────


def test_gas_first_generation_writes_the_extracted_baseline():
    # No baseline yet -> every row is new -> written, and the run fails until it is committed.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        result = run_regression_of(base, "gas", GAS_LOG)
        recorded = base / "regression" / "gas.txt"
        assert recorded.exists()
        assert "mintPeggedToken" in recorded.read_text()
        assert result.returncode == 1


def test_gas_no_change_holds_and_leaves_the_working_copy_untouched():
    # A held run must not rewrite the file: an uncommitted edit to the working copy survives, because
    # the baseline is the index and the merge writes only on a change.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        run_regression_of(base, "gas", GAS_LOG)
        _git(base, "add", "regression/gas.txt")
        _git(base, "commit", "-q", "-m", "baseline")
        recorded = base / "regression" / "gas.txt"
        recorded.write_text(recorded.read_text() + "# uncommitted edit\n")

        result = run_regression_of(base, "gas", GAS_LOG)
        assert result.returncode == 0
        assert "# uncommitted edit" in recorded.read_text()
        assert "No changes detected" in result.stderr


def test_gas_change_is_written_and_reported():
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        run_regression_of(base, "gas", GAS_LOG)
        _git(base, "add", "regression/gas.txt")
        _git(base, "commit", "-q", "-m", "baseline")

        result = run_regression_of(base, "gas", GAS_LOG_REGRESSED)
        assert result.returncode == 1
        assert "changed" in result.stderr
        assert "200000" in (base / "regression" / "gas.txt").read_text()


def test_gas_staged_deletion_fails_fast_before_the_run():
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        run_regression_of(base, "gas", GAS_LOG)
        _git(base, "add", "regression/gas.txt")
        _git(base, "commit", "-q", "-m", "baseline")
        (base / "regression" / "gas.txt").unlink()
        _git(base, "add", "regression/gas.txt")  # stage the deletion

        result = run_regression_of(base, "gas", GAS_LOG)
        assert result.returncode == 1
        assert "git restore --staged --worktree regression/gas.txt" in result.stderr
        assert "Minter_v3" not in result.stdout  # fail-fast: the run never happened


# ── run and extract failures stop the pipeline ───────────────────────────────


def test_run_failure_is_reported_and_stops_before_writing():
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        result = run_regression_of(base, "gas", GAS_LOG, exit_code=3)
        assert result.returncode == 1
        assert "gas failed (exit code 3)" in result.stderr
        assert not (base / "regression" / "gas.txt").exists()


def test_extract_failure_is_reported():
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        result = run_regression_of(base, "gas", MALFORMED_GAS_LOG)
        assert result.returncode != 0
        assert "extract-gas failed" in result.stderr


# ── the fallback paths: no compare script (sizes), and no extract script either ──


def test_sizes_uses_the_exact_match_fallback():
    # sizes has an extract script but no compare-sizes.py -> any difference is a change; an identical
    # re-run holds.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        first = run_regression_of(base, "sizes", SIZES_LOG)
        recorded = base / "regression" / "sizes.txt"
        assert recorded.exists()
        assert "MinimalStub" in recorded.read_text()
        assert first.returncode == 1

        _git(base, "add", "regression/sizes.txt")
        _git(base, "commit", "-q", "-m", "baseline")
        held = run_regression_of(base, "sizes", SIZES_LOG)
        assert held.returncode == 0


def test_type_without_an_extract_script_uses_the_raw_log():
    # A type with no extract script uses the raw run log as its extract (and, with no compare script,
    # exact-match) - both fallbacks in one.
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        result = run_regression_of(base, "faketype", "raw output line\n")
        recorded = base / "regression" / "faketype.txt"
        assert recorded.exists()
        assert "raw output line" in recorded.read_text()
        assert result.returncode == 1


# ── plumbing ─────────────────────────────────────────────────────────────────


def test_inner_output_is_passed_through():
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        result = run_regression_of(base, "gas", GAS_LOG)
        assert "Minter_v3" in result.stdout  # the run's log reached the console


def test_only_the_regression_file_and_its_log_remain():
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        _init_repo(base)
        run_regression_of(base, "gas", GAS_LOG)
        assert sorted(p.name for p in (base / "regression").iterdir()) == ["gas.log", "gas.txt"]
