#!/usr/bin/env python3
"""Run the test suite fuzzed far harder than `run test` does, for a run left going overnight.

Each seed is a full `run test` with FOUNDRY_FUZZ_RUNS runs per fuzz test - 5000 unless the caller sets
it. Seed 1 is always one of them, because coverage fuzzes with it; the others are fresh every run, so
successive nights explore new inputs instead of repeating the same ones. Every seed is announced, so a
failure replays with `--fuzz-seed <seed>`. Every seed runs even after one fails.

Arguments other than --log-file are passed to forge, so one file can be stressed on its own:
    run test-long --match-path test/Minter_fees.t.sol
    FOUNDRY_FUZZ_RUNS=20000 run test-long --match-path test/Minter_fees.t.sol

Output goes to the console and to a new tmp/test-long-<timestamp>.log, or is appended to the log named
by --log-file (which is how CI-long keeps one log for the whole night).

FOUNDRY_FUZZ_RUNS does not reach invariant tests, which take FOUNDRY_INVARIANT_RUNS.
"""

import argparse
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import logged_run  # noqa: E402

DEFAULT_FUZZ_RUNS = "5000"


def main():
    # allow_abbrev=False: forge's own flags pass through untouched, rather than being taken for an
    # abbreviation of --log-file
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0], allow_abbrev=False)
    parser.add_argument("--log-file", type=Path, help="append to this log instead of creating a new one")
    options, forge_args = parser.parse_known_args()

    log = options.log_file or logged_run.timestamped_log("test-long")
    fuzz_runs = os.environ.get("FOUNDRY_FUZZ_RUNS", DEFAULT_FUZZ_RUNS)
    env = {**os.environ, "FOUNDRY_FUZZ_RUNS": fuzz_runs}
    # absolute: inside bao-base BAO_BASE_DIR is ".", and pathlib renders "./run" as a bare "run", which
    # PATH lookup hands to the `run` yarn puts there (`yarn run`)
    run = Path(os.environ["BAO_BASE_DIR"]).resolve() / "run"

    logged_run.announce(f"=== test-long logging to {log} ===", log)
    failed = []
    for seed in [1, secrets.randbits(32), secrets.randbits(32)]:
        logged_run.announce(f"=== test-long --fuzz-seed {seed}, {fuzz_runs} fuzz runs ===", log)
        status = logged_run.run_logged([str(run), "test", "--fuzz-seed", str(seed), *forge_args], log, env)
        if status != 0:
            failed.append(str(seed))

    if failed:
        logged_run.announce(f"=== test-long FAILED for --fuzz-seed: {' '.join(failed)} ===", log)
        return 1
    logged_run.announce("=== test-long passed for every seed ===", log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
