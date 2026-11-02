"""Tests for the forge runs bin/test, bin/gas and bin/coverage make, built by bin/forge_test_runs.py: the
command each run hands forge, the environment every run gets - so that no project's foundry.toml has to
carry it - and what reaches forge when an entry point is run.

The command is built by a function and tested as a value. Each entry point is then run from a throwaway
working directory with a stub `forge` first on PATH, which records the environment and the arguments it
was called with instead of running anything. Each test names the single behaviour it verifies.
"""

import json
import os
import pathlib
import subprocess
import sys

import pytest

import forge_test_runs

_BIN = pathlib.Path(__file__).resolve().parents[2] / "bin"
_RUNS = ["test", "gas", "coverage"]
_INVARIANT_SETTINGS = ("FOUNDRY_INVARIANT_FAIL_ON_REVERT", "FOUNDRY_INVARIANT_RUNS", "FOUNDRY_INVARIANT_DEPTH")
_EVERY_RUN = ["--no-dynamic-test-linking", "--nmp", "script/**/*.t.sol"]

# records how forge was called - its environment and its arguments, and what the run had made for it - as
# JSON, runs nothing, and exits with the status STUB_FORGE_STATUS names
_STUB_FORGE = """#!/usr/bin/env bash
python3 - "$@" <<'EOF'
import json, os, sys
with open(os.environ["STUB_FORGE_RECORD"], "w") as record:
    json.dump({
        "env": dict(os.environ),
        "argv": sys.argv[1:],
        "results_exists": os.path.isdir("results"),
        "logs_root_exists": os.path.isdir(os.environ.get("BAO_DEPLOYMENT_LOGS_ROOT", "")),
    }, record)
EOF
exit "${STUB_FORGE_STATUS:-0}"
"""


def _forge_saw(
    tmp_path: pathlib.Path, run: str, arguments: list[str] = [], env: dict[str, str] | None = None, status: int = 0
) -> dict:
    """Run bin/<run> with `arguments`, `env` set in its environment and a stub forge on PATH that exits with
    `status`; what forge was called with, and the run's own exit status as "status". The invariant settings
    are absent from the environment unless `env` sets them, so the test's shell does not leak into the
    result."""
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir(exist_ok=True)
    stub = stub_dir / "forge"
    stub.write_text(_STUB_FORGE)
    stub.chmod(0o755)
    record = tmp_path / f"{run}.json"
    work = tmp_path / "work"
    work.mkdir(exist_ok=True)
    process_env = {name: value for name, value in os.environ.items() if name not in _INVARIANT_SETTINGS}
    process_env.update(env or {})
    process_env["PATH"] = f"{stub_dir}{os.pathsep}{os.environ['PATH']}"
    process_env["STUB_FORGE_RECORD"] = str(record)
    process_env["STUB_FORGE_STATUS"] = str(status)
    result = subprocess.run(
        [sys.executable, str(_BIN / run), *arguments],
        cwd=work,
        env=process_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status, result.stdout + result.stderr
    return json.loads(record.read_text()) | {"status": result.returncode}


# ── command: what each run is for, as the arguments it hands forge ──
def test_the_test_run_keeps_its_build_cache_and_summarises():
    assert forge_test_runs.command("test", {}, []) == [
        "forge",
        "test",
        "-v",
        *_EVERY_RUN,
        "--deny",
        "never",
        "--summary",
    ]


def test_the_gas_run_measures_in_isolation_on_its_own_cache_and_fails_on_a_warning():
    assert forge_test_runs.command("gas", {}, []) == [
        "forge",
        "test",
        "-s",
        "--out",
        "out/_gas",
        "--cache-path",
        "cache/_gas",
        *_EVERY_RUN,
        "--no-match-test",
        "_notInGasReport",
        "--isolate",
        "--gas-report",
        "--fuzz-seed",
        "1",
        "--fuzz-runs",
        "64",
        "--deny",
        "warnings",
    ]


def test_the_coverage_run_lifts_the_block_gas_limit_and_pins_its_seed():
    assert forge_test_runs.command("coverage", {}, []) == [
        "forge",
        "coverage",
        "-v",
        *_EVERY_RUN,
        "--fuzz-seed",
        "1",
        "--report",
        "summary",
        "--report",
        "lcov",
        "--deny",
        "never",
        "--disable-block-gas-limit",
    ]


@pytest.mark.parametrize("run", _RUNS)
def test_verbosity_follows_bao_base_verbosity(run):
    command = forge_test_runs.command(run, {"BAO_BASE_VERBOSITY": "3"}, [])
    assert "-vvv" in command
    assert "-v" not in command and "-s" not in command


@pytest.mark.parametrize("run", _RUNS)
def test_a_callers_arguments_follow_the_runs_own(run):
    assert forge_test_runs.command(run, {}, ["--match-contract", "X"])[-2:] == ["--match-contract", "X"]


# ── the entry points: what reaches forge ──
@pytest.mark.parametrize("run", _RUNS)
def test_forge_is_called_with_the_runs_command(tmp_path, run):
    seen = _forge_saw(tmp_path, run, ["--match-contract", "X"])
    assert seen["argv"] == forge_test_runs.command(run, {}, ["--match-contract", "X"])[1:]


@pytest.mark.parametrize("run", _RUNS)
def test_forges_exit_status_is_the_runs(tmp_path, run):
    assert _forge_saw(tmp_path, run, status=3)["status"] == 3


@pytest.mark.parametrize("run", _RUNS)
def test_the_results_folder_exists_before_forge_runs(tmp_path, run):
    # tests write their regression output under results/, which forge's fs_permissions allow but do not create
    assert _forge_saw(tmp_path, run)["results_exists"]


@pytest.mark.parametrize("run", ["gas", "coverage"])
def test_a_deploying_test_logs_under_a_folder_the_run_makes_and_removes(tmp_path, run):
    seen = _forge_saw(tmp_path, run)
    logs_root = seen["env"]["BAO_DEPLOYMENT_LOGS_ROOT"]
    assert logs_root.startswith("tmp/") and seen["logs_root_exists"], logs_root
    assert not (tmp_path / "work" / logs_root).exists()


def test_the_test_run_names_no_folder_for_deployment_logs(tmp_path):
    assert "BAO_DEPLOYMENT_LOGS_ROOT" not in _forge_saw(tmp_path, "test")["env"]


def test_coverage_tells_the_contracts_it_is_coverage(tmp_path):
    assert _forge_saw(tmp_path, "coverage")["env"]["BAO_COVERAGE_RUN"] == "true"


@pytest.mark.parametrize("run", ["test", "gas"])
def test_only_coverage_tells_the_contracts_it_is_coverage(tmp_path, run):
    assert "BAO_COVERAGE_RUN" not in _forge_saw(tmp_path, run)["env"]


# ── the invariant settings every run gets, from the wrapper rather than from a project's foundry.toml ──
@pytest.mark.parametrize("run", _RUNS)
def test_a_handler_call_that_reverts_fails_the_run(tmp_path, run):
    # forge discards a reverting handler call unless told otherwise, and the run then passes however many
    # revert; every run tells it otherwise
    assert _forge_saw(tmp_path, run)["env"]["FOUNDRY_INVARIANT_FAIL_ON_REVERT"] == "true"


@pytest.mark.parametrize("run", _RUNS)
def test_a_caller_cannot_let_a_reverting_handler_call_pass(tmp_path, run):
    # a run that passed over reverts would be a pass that proves nothing, so the setting is not a default
    seen = _forge_saw(tmp_path, run, env={"FOUNDRY_INVARIANT_FAIL_ON_REVERT": "false"})
    assert seen["env"]["FOUNDRY_INVARIANT_FAIL_ON_REVERT"] == "true"


@pytest.mark.parametrize("run", _RUNS)
def test_invariant_runs_and_depth_default_to_the_shared_tuning(tmp_path, run):
    seen = _forge_saw(tmp_path, run)["env"]
    assert (seen["FOUNDRY_INVARIANT_RUNS"], seen["FOUNDRY_INVARIANT_DEPTH"]) == ("64", "128")


@pytest.mark.parametrize("run", _RUNS)
def test_a_caller_can_ask_for_a_longer_invariant_run(tmp_path, run):
    # the tuning is a default: a caller's own value reaches forge unchanged
    seen = _forge_saw(tmp_path, run, env={"FOUNDRY_INVARIANT_RUNS": "5000", "FOUNDRY_INVARIANT_DEPTH": "1000"})
    assert (seen["env"]["FOUNDRY_INVARIANT_RUNS"], seen["env"]["FOUNDRY_INVARIANT_DEPTH"]) == ("5000", "1000")
