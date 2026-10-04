#!/usr/bin/env python3
"""Run test-long and then CI, for a run left going overnight so the tree is ready to commit by morning.

test-long fuzzes hard; CI rewrites the regression baselines and runs every check. CI runs even when
test-long fails, so the morning has the baselines and checks as well as the failing seeds. The run fails
if either does.

Both write to one new tmp/CI-long-<timestamp>.log, as well as to the console. Arguments are passed to
test-long, and from there to forge.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import logged_run  # noqa: E402


def main():
    log = logged_run.timestamped_log("CI-long")
    # absolute: inside bao-base BAO_BASE_DIR is ".", and pathlib renders "./run" as a bare "run", which
    # PATH lookup hands to the `run` yarn puts there (`yarn run`)
    run = Path(os.environ["BAO_BASE_DIR"]).resolve() / "run"

    logged_run.announce(f"=== CI-long logging to {log} ===", log)
    # test-long writes this same log itself, so its output is not captured here as well
    long_status = subprocess.run([str(run), "test-long", "--log-file", str(log), *sys.argv[1:]], check=False).returncode
    ci_status = logged_run.run_logged([str(run), "CI"], log)

    logged_run.announce(f"=== CI-long: test-long exit {long_status}, CI exit {ci_status} ===", log)
    if long_status != 0 or ci_status != 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
