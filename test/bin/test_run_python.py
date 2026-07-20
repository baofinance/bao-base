"""
Tests for bin/run-python — how a Python bin script's exit status reaches its caller.

A script that runs and chooses a non-zero exit code has NOT failed to run, and the two must not be
conflated: the status has to reach the caller intact so a wrapper can tell "the tests reported a
regression" from "the tooling broke". `regression-of` currently bypasses run-python entirely, with
a comment saying so, precisely because the status used to be collapsed.

run-python is both SOURCED (run:144, regression-of:35) and EXECUTED directly (validate:127,147 and
slither/run.sh:7,11), so it must not end in a bare `return` or a bare `exit` — the codebase idiom
for setting a status that works either way is `( exit "$status" )`, as bin/gas already does.
"""
import subprocess
from pathlib import Path

RUN = Path(__file__).resolve().parents[2] / "run"
# duration-of prints usage and exits 2 when given no command. Any bin script with a stable non-1,
# non-zero exit would do; what matters is that the value is distinguishable from a collapsed 1.
USAGE_EXIT_SCRIPT = "duration-of"
USAGE_EXIT_CODE = 2


def run_script(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(RUN), *args], cwd=RUN.parent, capture_output=True, text=True)


def test_script_exit_code_reaches_run_intact():
    # run-python hands the script's own status up rather than substituting one, which is what lets a
    # caller tell a reported regression from a broken tool. `run` itself then reports that status and
    # exits 1 (run:162 calls `error`, which exits, making its own `return $exit_code` on the next line
    # unreachable) — so the code is asserted where run-python delivers it, in the reported status.
    result = run_script(USAGE_EXIT_SCRIPT)
    assert result.returncode != 0
    assert f"failed with code {USAGE_EXIT_CODE}" in (result.stdout + result.stderr)


def test_a_script_that_ran_is_not_reported_as_having_failed_to_run():
    # The old message asserted a cause it never checked. It fired for every failing pytest run too,
    # claiming the tooling broke when the tests had simply reported failures.
    result = run_script(USAGE_EXIT_SCRIPT)
    assert "Failed to run Python script" not in (result.stdout + result.stderr)


def test_successful_script_still_exits_zero():
    result = run_script("nothing-python")
    assert result.returncode == 0
