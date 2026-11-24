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
_EVERY_RUN = [
    "--gas-limit",
    "18446744073709551615",
    "--disable-block-gas-limit",
    "--no-dynamic-test-linking",
    "--nmp",
    "script/**/*.t.sol",
]

# records each call forge gets - its environment and its arguments, and what the run had made for it - as a
# line of JSON, prints a line, writes the results STUB_FORGE_RESULTS holds where --json-file says
# (STUB_FORGE_RERUN_RESULTS from its second call on, when set), writes the reads STUB_FORGE_CHECK holds as a
# check named `gold` would, runs nothing, and exits with the status STUB_FORGE_STATUS names, or
# STUB_FORGE_RERUN_STATUS from its second call on
_STUB_FORGE = """#!/usr/bin/env bash
python3 - "$@" <<'EOF'
import json, os, shutil, sys
argv = sys.argv[1:]
folder = os.environ.get("BAO_CHECK_FOLDER", "")
with open(os.environ["STUB_FORGE_RECORD"], "a") as record:
    record.write(json.dumps({
        "env": dict(os.environ),
        "argv": argv,
        "results_exists": os.path.isdir("results"),
        "logs_root_exists": os.path.isdir(os.environ.get("BAO_DEPLOYMENT_LOGS_ROOT", "")),
        "listing": open(os.environ["BAO_CHECK_LISTING"]).read() if os.environ.get("BAO_CHECK_LISTING") else None,
        "checks_left": sorted(os.listdir(folder)) if folder and os.path.isdir(folder) else None,
    }) + "\\n")
print("the stub forge ran")
calls = sum(1 for _ in open(os.environ["STUB_FORGE_RECORD"]))
results = os.environ.get("STUB_FORGE_RESULTS")
if calls > 1 and os.environ.get("STUB_FORGE_RERUN_RESULTS"):
    results = os.environ["STUB_FORGE_RERUN_RESULTS"]
if "--json-file" in argv and results:
    shutil.copy(results, argv[argv.index("--json-file") + 1])
if os.environ.get("STUB_FORGE_CHECK"):
    os.makedirs(os.path.join(folder, "gold"))
    for name, lines in json.loads(os.environ["STUB_FORGE_CHECK"]).items():
        with open(os.path.join(folder, "gold", name), "w") as read:
            read.write("\\n".join(lines) + "\\n")
EOF
if [[ $(wc -l <"$STUB_FORGE_RECORD") -gt 1 ]]; then exit "${STUB_FORGE_RERUN_STATUS:-0}"; fi
exit "${STUB_FORGE_STATUS:-0}"
"""


def _forge_saw(
    tmp_path: pathlib.Path,
    run: str,
    arguments: list[str] = [],
    env: dict[str, str] | None = None,
    status: int = 0,
    results: dict | None = None,
    rerun_status: int = 0,
    rerun_results: dict | None = None,
) -> dict:
    """Run bin/<run> with `arguments`, `env` set in its environment and a stub forge on PATH that exits with
    `status` (`rerun_status` from its second call on) and writes `results` (`rerun_results` from its second
    call on, when given), the JSON forge's --json-file writes, where the run asks; what forge's first call was called with, every call as "calls", the run's
    own exit status as "status" and what it printed as "stderr". The invariant settings are absent from the
    environment unless `env` sets them, so the test's shell does not leak into the result."""
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
    process_env["STUB_FORGE_RERUN_STATUS"] = str(rerun_status)
    if results is not None:
        results_file = tmp_path / "results.json"
        results_file.write_text(json.dumps(results))
        process_env["STUB_FORGE_RESULTS"] = str(results_file)
    if rerun_results is not None:
        rerun_results_file = tmp_path / "rerun-results.json"
        rerun_results_file.write_text(json.dumps(rerun_results))
        process_env["STUB_FORGE_RERUN_RESULTS"] = str(rerun_results_file)
    result = subprocess.run(
        [sys.executable, str(_BIN / run), *arguments],
        cwd=work,
        env=process_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert record.exists(), result.stdout + result.stderr
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    return calls[0] | {"status": result.returncode, "calls": calls, "stderr": result.stderr}


def _results(**suites: dict[str, str | None]) -> dict:
    """forge's results file for `suites`, each a suite's name to its tests' failure reasons, None for a pass."""
    return {
        suite: {
            "duration": {"secs": 0, "nanos": 0},
            "test_results": {
                test: {"status": "Failure" if reason else "Success", "reason": reason} for test, reason in tests.items()
            },
            "warnings": [],
        }
        for suite, tests in suites.items()
    }


# three ways a provider failure reads, in forge 1.9.0's words: its JSON-RPC error, forge's retries exhausted on
# its refusals, and the fork backend's read failing
_A_PROVIDERS_ERROR = (
    "vm.createSelectFork: could not instantiate forked environment with provider mainnet.infura.io; server "
    "returned an error response: error code -32603: precondition failure"
)
_RETRIES_EXHAUSTED = 'Max retries exceeded HTTP error 429 with body: {"code":-32005,"message":"Too Many Requests"}'
_A_READ_FAILED = "sharedbackend: Failed to send/recv `basic`"
_AN_ASSERTION = "assertion failed: 1 != 2"
_A_REVERT = "revert: boom"


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
        "--json-file",
        "tmp/forge-test-results.json",
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


def test_the_coverage_run_pins_its_seed_and_reports_both_ways():
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
    ]


@pytest.mark.parametrize("run", _RUNS)
def test_every_run_lifts_the_block_gas_limit(run):
    # a forked test takes the forked block's gas limit, which one call running a whole deploy or upgrade
    # exceeds; lifted by the run and never in foundry.toml, where it would reach a script's simulation
    assert "--disable-block-gas-limit" in forge_test_runs.command(run, {}, [])


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


# ── the gas run's fuzz inputs follow its seed alone, not the bytecode under test ──
_BYTECODE_CONSTANTS = ("FOUNDRY_FUZZ_INCLUDE_PUSH_BYTES", "FOUNDRY_INVARIANT_INCLUDE_PUSH_BYTES")


def test_the_gas_runs_fuzz_inputs_leave_out_the_bytecodes_constants(tmp_path):
    # forge adds the constants in the deployed bytecode to its fuzz inputs by default, so any edit to a
    # contract changes which calls the gas report measures; the run's numbers are a baseline, so a caller's
    # own setting is replaced
    seen = _forge_saw(tmp_path, "gas", env=dict.fromkeys(_BYTECODE_CONSTANTS, "true"))["env"]
    assert [seen[name] for name in _BYTECODE_CONSTANTS] == ["false", "false"]


@pytest.mark.parametrize("run", ["test", "coverage"])
def test_only_the_gas_run_leaves_the_bytecodes_constants_out(tmp_path, run):
    # the constants help the fuzzer find a bug, so the other runs hand forge whatever the caller set
    seen = _forge_saw(tmp_path, run, env=dict.fromkeys(_BYTECODE_CONSTANTS, "true"))["env"]
    assert [seen[name] for name in _BYTECODE_CONSTANTS] == ["true", "true"]


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


# ── the test run re-runs the suites a provider error failed, once, and says so ──
def test_the_test_run_writes_forges_results_under_tmp(tmp_path):
    seen = _forge_saw(tmp_path, "test")
    argv = seen["argv"]
    assert argv[argv.index("--json-file") + 1].startswith("tmp/")
    assert (tmp_path / "work" / "tmp").is_dir()


def test_a_test_run_without_a_failure_calls_forge_once(tmp_path):
    seen = _forge_saw(tmp_path, "test", results=_results(**{"test/A.t.sol:A": {"test_a()": None}}))
    assert len(seen["calls"]) == 1
    assert seen["status"] == 0


@pytest.mark.parametrize("reason", [_A_PROVIDERS_ERROR, _RETRIES_EXHAUSTED, _A_READ_FAILED])
def test_failures_a_provider_error_caused_are_rerun_once_and_named(tmp_path, reason):
    # the failed suites are re-run whole, by name: a suite whose setUp failed has every test to run again, and
    # forge's own --rerun records a test's failure but not a setUp's
    results = _results(
        **{"test/A.t.sol:A": {"test_a()": reason, "test_b()": None}, "test/B.t.sol:B": {"setUp()": reason}}
    )
    seen = _forge_saw(tmp_path, "test", ["--match-path", "test/*"], status=1, results=results)
    first, second = seen["calls"]
    assert second["argv"] == [*first["argv"], "--match-contract", "^(A|B)$"]
    assert seen["status"] == 0
    assert "test/A.t.sol:A" in seen["stderr"] and "test/B.t.sol:B" in seen["stderr"], seen["stderr"]
    assert reason[:40] in seen["stderr"], seen["stderr"]


def test_a_rerun_that_fails_fails_the_run(tmp_path):
    results = _results(**{"test/A.t.sol:A": {"setUp()": _A_PROVIDERS_ERROR}})
    seen = _forge_saw(tmp_path, "test", status=1, results=results, rerun_status=2)
    assert len(seen["calls"]) == 2
    assert seen["status"] == 2


@pytest.mark.parametrize("reason", [_AN_ASSERTION, _A_REVERT])
def test_a_failure_that_is_not_a_provider_error_is_not_rerun(tmp_path, reason):
    results = _results(**{"test/A.t.sol:A": {"test_a()": reason, "test_b()": None}})
    seen = _forge_saw(tmp_path, "test", status=1, results=results)
    assert len(seen["calls"]) == 1
    assert seen["status"] == 1
    assert "re-running" not in seen["stderr"]


def test_a_provider_error_beside_another_failure_is_not_rerun(tmp_path):
    # the other failure is real, and a re-run would only delay it
    results = _results(
        **{"test/A.t.sol:A": {"test_a()": _A_PROVIDERS_ERROR}, "test/B.t.sol:B": {"test_b()": _AN_ASSERTION}}
    )
    seen = _forge_saw(tmp_path, "test", status=1, results=results)
    assert len(seen["calls"]) == 1
    assert seen["status"] == 1


def test_a_failed_run_that_left_no_results_is_not_rerun(tmp_path):
    # forge failed before it wrote any: a build error, say
    seen = _forge_saw(tmp_path, "test", status=1)
    assert len(seen["calls"]) == 1
    assert seen["status"] == 1


@pytest.mark.parametrize("run", ["gas", "coverage"])
def test_gas_and_coverage_never_rerun(tmp_path, run):
    # their report is of one run, and a re-run's would be partial
    results = _results(**{"test/A.t.sol:A": {"setUp()": _A_PROVIDERS_ERROR}})
    seen = _forge_saw(tmp_path, run, status=1, results=results)
    assert len(seen["calls"]) == 1
    assert seen["status"] == 1
    assert "--json-file" not in seen["argv"]


# ── the run ends by saying what it re-ran and what it did not ──
def test_a_rerun_that_passed_is_reported_at_the_end(tmp_path):
    results = _results(
        **{"test/A.t.sol:A": {"setUp()": _A_PROVIDERS_ERROR}, "test/B.t.sol:B": {"test_b()": _A_READ_FAILED}}
    )
    passed = _results(**{"test/A.t.sol:A": {"test_a()": None}, "test/B.t.sol:B": {"test_b()": None}})
    seen = _forge_saw(tmp_path, "test", status=1, results=results, rerun_results=passed)
    lines = seen["stderr"].splitlines()
    summary = lines.index("the provider failed 2 tests in 2 suites; re-run once:")
    assert lines[summary + 1 :] == [
        f"  test/A.t.sol:A setUp(): {_A_PROVIDERS_ERROR}",
        f"  test/B.t.sol:B test_b(): {_A_READ_FAILED}",
        "re-run: all passed",
    ], seen["stderr"]


def test_a_rerun_that_failed_names_what_still_fails(tmp_path):
    results = _results(**{"test/B.t.sol:B": {"test_b()": _A_READ_FAILED}})
    still = _results(**{"test/B.t.sol:B": {"test_b()": _A_PROVIDERS_ERROR}})
    seen = _forge_saw(tmp_path, "test", status=1, results=results, rerun_status=1, rerun_results=still)
    assert seen["status"] == 1
    assert seen["stderr"].splitlines()[-4:] == [
        "the provider failed 1 test in 1 suite; re-run once:",
        f"  test/B.t.sol:B test_b(): {_A_READ_FAILED}",
        "re-run: 1 still failed:",
        f"  test/B.t.sol:B test_b(): {_A_PROVIDERS_ERROR}",
    ], seen["stderr"]


def test_failures_not_rerun_are_named_with_the_providers_beside_them(tmp_path):
    results = _results(
        **{
            "test/A.t.sol:A": {"test_a()": _A_PROVIDERS_ERROR},
            "test/C.t.sol:C": {"test_c()": _AN_ASSERTION, "test_d()": _A_REVERT},
        }
    )
    seen = _forge_saw(tmp_path, "test", status=1, results=results)
    assert seen["stderr"].splitlines()[-5:] == [
        "not re-run: 2 failed for reasons not the provider's:",
        f"  test/C.t.sol:C test_c(): {_AN_ASSERTION}",
        f"  test/C.t.sol:C test_d(): {_A_REVERT}",
        "beside 1 the provider failed:",
        f"  test/A.t.sol:A test_a(): {_A_PROVIDERS_ERROR}",
    ], seen["stderr"]


def test_a_failed_run_that_left_no_results_says_so(tmp_path):
    # a results file left by an earlier run is not read: forge wrote none this run, as after a build error
    stale = tmp_path / "work" / "tmp" / "forge-test-results.json"
    stale.parent.mkdir(parents=True)
    stale.write_text(json.dumps(_results(**{"test/A.t.sol:A": {"setUp()": _A_PROVIDERS_ERROR}})))
    seen = _forge_saw(tmp_path, "test", status=1)
    assert len(seen["calls"]) == 1
    assert seen["stderr"].splitlines()[-1] == "no results file; nothing re-run", seen["stderr"]


def test_a_clean_run_prints_no_summary(tmp_path):
    seen = _forge_saw(tmp_path, "test", results=_results(**{"test/A.t.sol:A": {"test_a()": None}}))
    assert "re-run" not in seen["stderr"] and "provider" not in seen["stderr"], seen["stderr"]


# ── the campaign run: bin/run-campaign-test ──

_CAMPAIGN = "script/verify/gold-emptying-executed"
_LOG = "tmp/gold.log"
_PASSED = _results(**{f"{_CAMPAIGN}/Gold.t.sol:Gold": {"test_a()": None}})
_HASH_A = "0x" + "a" * 64
_HASH_B = "0x" + "b" * 64
_STATE = {"proxies": {"GOLD::pool": {"address": "0x00000000000000000000000000000000000000A1"}}, "implementations": {}}


def _campaign(
    tmp_path: pathlib.Path,
    arguments: list[str],
    results: dict | None = _PASSED,
    check: dict[str, list[str]] | None = None,
    **stub: object,
) -> dict:
    """Run bin/run-campaign-test on the campaign with the log, then `arguments`, a state file `state.json` in the
    working directory, and a stub forge that writes `results` and, with `check`, a check's reads; what forge was
    called with each time as "calls" (none when the run stopped before forge), and the run's status, output and
    working directory."""
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir(parents=True, exist_ok=True)
    (stub_dir / "forge").write_text(_STUB_FORGE)
    (stub_dir / "forge").chmod(0o755)
    record = tmp_path / "campaign.json"
    work = tmp_path / "work"
    work.mkdir(exist_ok=True)
    (work / "state.json").write_text(json.dumps(_STATE))
    env = {name: value for name, value in os.environ.items() if name not in _INVARIANT_SETTINGS}
    env["PATH"] = f"{stub_dir}{os.pathsep}{os.environ['PATH']}"
    env["STUB_FORGE_RECORD"] = str(record)
    env["STUB_FORGE_STATUS"] = str(stub.get("status", 0))
    env["STUB_FORGE_RERUN_STATUS"] = str(stub.get("rerun_status", 0))
    for name, value in (("STUB_FORGE_RESULTS", results), ("STUB_FORGE_RERUN_RESULTS", stub.get("rerun_results"))):
        if value is not None:
            file = tmp_path / f"{name}.json"
            file.write_text(json.dumps(value))
            env[name] = str(file)
    if check is not None:
        env["STUB_FORGE_CHECK"] = json.dumps(check)
    done = subprocess.run(
        [sys.executable, str(_BIN / "run-campaign-test"), _CAMPAIGN, _LOG, *arguments],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    calls = [json.loads(line) for line in record.read_text().splitlines()] if record.exists() else []
    return {"status": done.returncode, "stdout": done.stdout, "stderr": done.stderr, "calls": calls, "work": work}


def test_a_campaign_run_points_forge_at_the_campaign_with_its_own_build(tmp_path):
    # its own build: the test directory moved, forge compiles with one remapping more, and every artifact differs from
    # the main build's; requests are paced for a provider that refuses a burst
    assert forge_test_runs.command("campaign", {}, ["-vv"], results="tmp/gold.results.json") == [
        "forge", "test", "-v", "--gas-limit", "18446744073709551615", "--disable-block-gas-limit",
        "--no-dynamic-test-linking", "--deny", "never", "--out", "out/_campaign", "--cache-path", "cache/_campaign",
        "--compute-units-per-second", "50", "--json-file", "tmp/gold.results.json", "-vv",
    ]  # fmt: skip
    seen = _campaign(tmp_path, ["--match-contract", "Gold"])
    (call,) = seen["calls"]
    assert call["env"]["FOUNDRY_TEST"] == _CAMPAIGN
    assert call["argv"] == forge_test_runs.command(
        "campaign", {}, ["--match-contract", "Gold"], results="tmp/gold.results.json"
    )[1:]
    assert seen["status"] == 0, seen["stderr"]


def test_a_campaign_run_leaves_the_campaigns_tests_in(tmp_path):
    # the test run leaves out the tests under script/, which is where a campaign's are
    (call,) = _campaign(tmp_path, [])["calls"]
    assert "--nmp" not in call["argv"]


def test_a_campaign_run_writes_forges_output_to_its_log_and_to_the_terminal(tmp_path):
    seen = _campaign(tmp_path, [])
    assert "the stub forge ran" in (seen["work"] / _LOG).read_text()
    assert "the stub forge ran" in seen["stdout"]


def test_a_campaign_run_that_ran_no_test_fails_saying_so(tmp_path):
    # forge runs tests only from its test directory: a filter that matches nothing reports no tests and exits 0
    seen = _campaign(tmp_path, ["--match-contract", "Nothing"], results={})
    assert seen["status"] == 1
    assert f"❌ forge ran no test in {_CAMPAIGN}: the campaign checked nothing" in seen["stderr"], seen["stderr"]


def test_the_network_and_local_give_where_the_batch_ran(tmp_path):
    on_mainnet = _campaign(tmp_path / "mainnet", ["--network", "mainnet"])["calls"][0]["env"]
    on_the_node = _campaign(tmp_path / "local", ["--network", "mainnet", "--local"])["calls"][0]["env"]
    neither = _campaign(tmp_path / "neither", [])["calls"][0]["env"]
    assert on_mainnet["EXECUTED_ON"] == "mainnet"
    assert on_the_node["EXECUTED_ON"] == "local"
    assert "EXECUTED_ON" not in neither


@pytest.mark.parametrize("arguments", [["--local"], ["--transactions", f"GOLD={_HASH_A}"]])
def test_local_or_transactions_without_a_network_stop_the_run(tmp_path, arguments):
    seen = _campaign(tmp_path, arguments)
    assert seen["calls"] == []
    assert seen["status"] == 1
    assert "❌ --local and --transactions name where a batch ran: they need --network" in seen["stderr"]


def test_transactions_are_given_by_name(tmp_path):
    # one name with one transaction, another with two, in the order given
    arguments = ["--network", "mainnet", "--transactions", f"GOLD={_HASH_A}", "--transactions"]
    seen = _campaign(tmp_path, [*arguments, f"SILVER={_HASH_A},{_HASH_B}"])
    env = seen["calls"][0]["env"]
    assert env["GOLD_TRANSACTIONS"] == _HASH_A
    assert env["SILVER_TRANSACTIONS"] == f"{_HASH_A},{_HASH_B}"


@pytest.mark.parametrize("given", [f"GOLD={_HASH_A[:-2]}", f"GOLD={_HASH_A}g", "GOLD=", f"gold={_HASH_A}", _HASH_A])
def test_a_transactions_value_not_a_name_and_hashes_stops_the_run(tmp_path, given):
    seen = _campaign(tmp_path, ["--network", "mainnet", "--transactions", given])
    assert seen["calls"] == []
    assert seen["status"] == 1
    assert (
        f"❌ --transactions takes <NAME>=<hash>[,<hash>...], each hash 32 bytes in hex, not '{given}'"
        in seen["stderr"]
    ), seen["stderr"]


def test_state_files_write_the_listing_beside_the_log_before_forge(tmp_path):
    seen = _campaign(tmp_path, ["--state", "state.json"])
    (call,) = seen["calls"]
    assert call["env"]["BAO_CHECK_LISTING"] == "tmp/gold.listing.tsv"
    expected = forge_test_runs.deployment_snap.listing_lines([_STATE], lambda contract_type: None)
    assert call["listing"] == "\n".join(expected) + "\n"


def test_a_type_without_a_state_file_stops_the_run(tmp_path):
    seen = _campaign(tmp_path, ["--type", "Pool_v1"])
    assert seen["calls"] == []
    assert "❌ --type adds a type to the listing --state writes: it needs --state" in seen["stderr"]


def test_the_checks_folder_is_beside_the_log_and_its_reads_are_sorted_after_forge(tmp_path):
    # a check writes its reads in the order it read them; a folder an earlier run left is gone before forge runs
    stale = tmp_path / "work" / "tmp" / "gold.checks" / "earlier"
    stale.mkdir(parents=True)
    reads = {"before.tsv": ["b\t2", "a\t1"], "after.tsv": ["d\t4", "c\t3"], "changes.tsv": ["z", "y"]}
    seen = _campaign(tmp_path, ["--state", "state.json"], check=reads)
    (call,) = seen["calls"]
    assert call["env"]["BAO_CHECK_FOLDER"] == "tmp/gold.checks"
    assert call["checks_left"] is None
    gold = seen["work"] / "tmp" / "gold.checks" / "gold"
    assert (gold / "before.tsv").read_text() == "a\t1\nb\t2\n"
    assert (gold / "after.tsv").read_text() == "c\t3\nd\t4\n"
    # the changes keep the order the check found them in
    assert (gold / "changes.tsv").read_text() == "z\ny\n"


def test_a_campaign_run_reruns_a_provider_failure_once(tmp_path):
    failed = _results(**{f"{_CAMPAIGN}/Gold.t.sol:Gold": {"setUp()": _A_PROVIDERS_ERROR}})
    seen = _campaign(tmp_path, [], results=failed, status=1, rerun_results=_PASSED)
    first, second = seen["calls"]
    assert second["argv"] == [*first["argv"], "--match-contract", "^(Gold)$"]
    assert seen["status"] == 0, seen["stderr"]
    assert "the stub forge ran\nthe stub forge ran\n" in (seen["work"] / _LOG).read_text()
