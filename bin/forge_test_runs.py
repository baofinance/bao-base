#!/usr/bin/env python3
"""The forge runs bin/test, bin/gas and bin/coverage make.

One command each, built here, so that the three agree on what every run gets and differ only in what each
is for. The entry points are the files `run` finds by the yarn script's name; each hands its name and the
caller's arguments to `main`. tests/bin/test_forge_test_runs.py pins every command and setting below.

Every run gets:

- The verbosity BAO_BASE_VERBOSITY asks for, as -v, -vv and so on. Without it, test and coverage run with
  -v, and gas with -s, which shows a failing test's logs and nothing else.

- --no-dynamic-test-linking, which works around a forge defect that makes tests pass against source they
  cannot pass against. Dynamic test linking (on by default since forge 1.8.0) rewrites `new Contract(...)`
  in a test into a deploy performed at run time, so the test file no longer needs recompiling when only
  that contract's body changes - and the build cache stops recompiling it. When the rewrite is not applied
  to a contract the cache skips the recompile anyway, so the test keeps running the creation code compiled
  into it earlier. Verified on forge 1.8.1: an edited aggregator reported all tests passing with gas figures
  identical to the digit, against a return statement that could not produce them. Reported as
  https://github.com/foundry-rs/foundry/issues/16682, which forge 1.8.3 fixed for contracts in the src
  directory. A contract outside src - how harbor's tests reach bao-base in lib/ - still loses the change on
  1.8.3, however it is imported: https://github.com/foundry-rs/foundry/issues/16901. Both bodies are kept
  in bug-reports/. Remove this flag once forge fixes 16901 - not before.
  tests/toolchain/test_forge_dynamic_test_linking.py fails if this flag is removed while the defect stands.
  The gas run has its own cache (--cache-path cache/_gas), so it goes stale independently of the test run:
  verified on forge 1.8.1, an edited contract reported the SAME gas to the digit, which is the one number
  that run exists to measure and the one a regression baseline would then freeze.

- --nmp "script/**/*.t.sol": the tests under script/ are verification campaigns, run by hand through their
  own runner before a deployment, and not the project's test suite.

- --gas-limit 18446744073709551615: the block gas limit of a test's own chain, lifted to the maximum so
  that a setUp deploying a whole stack is not capped at forge's default of 2^30. A forked test takes the
  forked block's limit instead, whatever this says. A run setting, so it lives here rather than in a
  project's foundry.toml, where it would reach forge script as well.

- --disable-block-gas-limit: a forked test takes the forked block's gas limit (60M on mainnet) in place of
  the one above, and one call running a whole deploy or upgrade - what a script sends as many transactions
  - exceeds it. So does a setUp deploying a stack of contracts under coverage, the one run that compiles
  with the optimizer off (forge does that so line data maps back to source), which inflates every
  contract's deployed code and with it the 200 gas per byte charged to deposit that code - a 40KB contract
  costs over 8M gas to deploy. Either way the create halts out of gas and setUp reverts with no indication
  of why. Lifted by the runs alone: in foundry.toml it would reach a script's simulation too, where the
  check is what catches a transaction no block can hold; doctor refuses it there.

- The invariant settings, as environment variables, so that no project's foundry.toml has to carry them:
  a handler call that reverts fails the run - forge discards such a call unless told otherwise, and the run
  then passes however many revert, so a handler whose every call reverts proves nothing; and the shared
  tuning of 64 runs at depth 128 as defaults, which a caller raises for a longer run by hand, as in
  `FOUNDRY_INVARIANT_RUNS=5000 yarn test --match-contract SomeInvariant`. The first is not a default a
  caller can lower: a run that passed over reverts would be a pass that proves nothing.

- A results/ folder: tests write their regression output there, which forge's fs_permissions allow but do
  not create.

What each run is for:

- test: --deny never keeps the build cache. With warnings denied (foundry.toml's `deny = "warnings"`), forge
  1.8.4 keeps none, because cached artifacts do not carry the warnings a warm build would have to re-check
  (https://github.com/foundry-rs/foundry/pull/17202), so every run would recompile the whole project.
  Warnings are still printed; gas is the run that fails on them.
  tests/toolchain/test_forge_deny_warnings_cache.py fails if either half of that changes.
  A failure the provider caused is re-run once. forge writes each test's result to tmp/forge-test-results.json
  (--json-file), and when every failure in the run reads as the provider's - its JSON-RPC error ("server
  returned an error response"), forge's retries on its refusals exhausted ("Max retries exceeded"), or the
  fork backend's read failing ("Failed to send/recv") - the run names each failure and runs forge again
  with the same arguments and `--match-contract` naming the failed suites, whole: a suite whose setUp failed
  has every test to run again. (forge's own `--rerun` records a test's failure but not a setUp's, and with
  nothing recorded runs everything.) The re-run's status is the run's. A failure that is not the provider's
  fails the run at once and re-runs nothing: a re-run would only delay a real failure, and would hide a test
  that fails on its own. The run ends by saying what it did: the provider's failures with each reason and
  whether the re-run passed or what still failed, or the failures it did not re-run, the provider's beside
  them, or that forge left no results file. A results file left by an earlier run is removed before forge
  runs, so one that is missing afterwards means forge wrote none.

- gas: the gas report, measured under --isolate, where every top-level call becomes its own transaction,
  with the fuzz seed pinned so two runs of the same code measure the same calls. `--no-match-test
  _notInGasReport` opts a test out of this run by name, the only selector forge offers: a many-iteration
  stress test can cost hundreds of times its neighbours while adding nothing the shorter tests do not
  already measure for the same functions. Such a test keeps that suffix; it still runs under test and
  coverage, where the iterations earn their keep. forge takes only the LAST --no-match-test, so a caller's
  own replaces this one rather than combining with it. --deny warnings makes this the run that fails on a
  compiler warning. Coverage cannot be the gate: it compiles with the optimizer off, and solc then warns
  that the larger contracts exceed the code size limit. Under denied warnings forge 1.8.4 keeps no cache,
  so this run always compiles in full and cache/_gas stays empty until forge caches again.

- coverage: --fuzz-seed 1: the baseline this run feeds (regression/coverage.txt) is compared exactly, so two
  runs of the same code must fuzz with the same inputs - an unpinned seed lets a branch that only some
  inputs reach come and go, and report a change that is not one. BAO_COVERAGE_RUN tells the Solidity code
  it is under coverage.

gas and coverage run deploy scripts whose logs go under BAO_DEPLOYMENT_LOGS_ROOT, a folder under tmp/ that
the run makes and removes. Neither is re-run on a provider failure: each reports one run, and a re-run's
report would be partial.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Mapping, Sequence
from pathlib import Path

from provider_failures import reads_as_the_providers

# where the test run has forge write each test's result
_TEST_RESULTS = "tmp/forge-test-results.json"

_EVERY_RUN = [
    "--gas-limit",
    "18446744073709551615",
    "--disable-block-gas-limit",
    "--no-dynamic-test-linking",
    "--nmp",
    "script/**/*.t.sol",
]


def _verbosity(environ: Mapping[str, str], quiet: str) -> str:
    """The verbosity flag: -v, -vv ... for BAO_BASE_VERBOSITY above zero, else `quiet`."""
    level = int(environ.get("BAO_BASE_VERBOSITY") or 0)
    return "-" + "v" * level if level > 0 else quiet


def command(run: str, environ: Mapping[str, str], arguments: Sequence[str]) -> list[str]:
    """The forge command the run `run` makes, with the caller's `arguments` after the run's own."""
    if run == "test":
        own = [
            "forge",
            "test",
            _verbosity(environ, "-v"),
            *_EVERY_RUN,
            "--deny",
            "never",
            "--summary",
            "--json-file",
            _TEST_RESULTS,
        ]
    elif run == "gas":
        own = [
            "forge",
            "test",
            _verbosity(environ, "-s"),
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
    elif run == "coverage":
        own = [
            "forge",
            "coverage",
            _verbosity(environ, "-v"),
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
    else:
        raise ValueError(f"no such run: {run}")
    return [*own, *arguments]


def invariant_settings(environ: Mapping[str, str]) -> dict[str, str]:
    """The invariant settings every run hands forge: the forced one, and the tuning as defaults a caller's
    own value replaces. An empty value counts as unset, as it does in a shell."""
    return {
        "FOUNDRY_INVARIANT_FAIL_ON_REVERT": "true",
        "FOUNDRY_INVARIANT_RUNS": environ.get("FOUNDRY_INVARIANT_RUNS") or "64",
        "FOUNDRY_INVARIANT_DEPTH": environ.get("FOUNDRY_INVARIANT_DEPTH") or "128",
    }


def _failures(results: Path) -> dict[str, dict[str, str]]:
    """The failed tests in forge's results file `results`, by suite, each with its reason."""
    failures: dict[str, dict[str, str]] = {}
    for suite, body in json.loads(results.read_text()).items():
        for test, outcome in body["test_results"].items():
            if outcome["status"] == "Failure":
                failures.setdefault(suite, {})[test] = outcome.get("reason") or ""
    return failures


def _count(failures: Mapping[str, Mapping[str, str]]) -> int:
    """The number of failed tests in `failures`."""
    return sum(len(tests) for tests in failures.values())


def _some(count: int, noun: str) -> str:
    """`count` of `noun`, in the plural when there is not exactly one: "1 test", "2 suites"."""
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def _say(heading: str, failures: Mapping[str, Mapping[str, str]]) -> None:
    """Print `heading` and a line per failed test in `failures`: its suite, its name and its reason's first line."""
    print(heading, file=sys.stderr)
    for suite, tests in failures.items():
        for test, reason in tests.items():
            print(f"  {suite} {test}: {reason.splitlines()[0] if reason else ''}", file=sys.stderr)
    sys.stderr.flush()


def main(run: str, arguments: Sequence[str]) -> int:
    """Make the run `run` with the caller's `arguments`; forge's exit status."""
    environ = {**os.environ, **invariant_settings(os.environ)}
    Path("results").mkdir(exist_ok=True)
    logs_root: str | None = None
    Path("tmp").mkdir(exist_ok=True)
    if run in ("gas", "coverage"):
        # named from the working directory, as the tests' file permissions are
        logs_root = os.path.relpath(tempfile.mkdtemp(dir="tmp"))
        environ["BAO_DEPLOYMENT_LOGS_ROOT"] = logs_root
    if run == "coverage":
        environ["BAO_COVERAGE_RUN"] = "true"
    forge = command(run, environ, arguments)
    print("+ " + shlex.join(forge), file=sys.stderr, flush=True)
    try:
        results = Path(_TEST_RESULTS)
        if run == "test":
            results.unlink(missing_ok=True)
        status = subprocess.run(forge, env=environ, check=False).returncode
        if run == "test" and status != 0:
            if not results.is_file():
                print("no results file; nothing re-run", file=sys.stderr, flush=True)
                return status
            failures = _failures(results)
            providers = {
                suite: {test: reason for test, reason in tests.items() if reads_as_the_providers(reason)}
                for suite, tests in failures.items()
            }
            providers = {suite: tests for suite, tests in providers.items() if tests}
            others = {
                suite: {test: reason for test, reason in tests.items() if not reads_as_the_providers(reason)}
                for suite, tests in failures.items()
            }
            others = {suite: tests for suite, tests in others.items() if tests}
            if others:
                _say(f"not re-run: {_count(others)} failed for reasons not the provider's:", others)
                if providers:
                    _say(f"beside {_count(providers)} the provider failed:", providers)
                return status
            if providers:
                summary = f"the provider failed {_some(_count(providers), 'test')} in {_some(len(providers), 'suite')}"
                print(f"{summary}; re-running them once", file=sys.stderr, flush=True)
                # the suites by their contract names, which is what --match-contract matches
                names = "|".join(re.escape(suite.rsplit(":", 1)[-1]) for suite in providers)
                rerun = [*forge, "--match-contract", f"^({names})$"]
                print("+ " + shlex.join(rerun), file=sys.stderr, flush=True)
                results.unlink(missing_ok=True)
                status = subprocess.run(rerun, env=environ, check=False).returncode
                _say(f"{summary}; re-run once:", providers)
                if not results.is_file():
                    print("re-run: no results file", file=sys.stderr, flush=True)
                elif still := _failures(results):
                    _say(f"re-run: {_count(still)} still failed:", still)
                else:
                    print("re-run: all passed", file=sys.stderr, flush=True)
        return status
    finally:
        if logs_root is not None:
            shutil.rmtree(logs_root, ignore_errors=True)
