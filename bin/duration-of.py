#!/usr/bin/env python3
"""
Record how long a run's test suites took, then check that against the committed baseline.

Usage: duration-of <command> [args...]
  duration-of test                                       -> regression/test-duration.txt
  duration-of regression-of gas                          -> regression/gas-duration.txt
  duration-of regression-of gas --no-match-contract 'X'  -> regression/gas-duration.txt

Duration is a DIMENSION of any run that executes tests, not a regression type of its own, so this
decorates a run from the outside rather than living inside `regression-of` — which covers the plain
`test` run (that does not use `regression-of` at all) and leaves `sizes` alone (a build has no
suites to time).

The inner command runs as a SUBPROCESS, and that is load-bearing rather than incidental.
`regression-of` calls `error`, which is `exit 1`, as a NORMAL outcome whenever a regression file
changes, and `run` dispatches bash scripts by SOURCING them — so a wrapper that sourced its inner
command would be terminated by it and lose the timings at exactly the moment a regression was being
reported. Being a Python script makes that structural: this cannot be sourced into `run`'s shell.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN_DIR))

import ratchet  # noqa: E402 - importable only after bin is on the path above

EXTRACT = BIN_DIR / "extract-duration.py"
COMPARE = BIN_DIR / "compare-duration.py"


def load(path):
    """Load a bin script as a module. Needed because a hyphen is not a valid module name."""
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def measure_name(args):
    """Name the measure after the run: the last positional argument before the first flag.

    `regression-of gas --no-match-contract 'RangeIntegral'` is named for `gas`, not for the trailing
    regex — so the name survives pass-through flags, which is why it is not simply the last argument.
    """
    positional = []
    for arg in args:
        if arg.startswith("-"):
            break
        positional.append(arg)
    if not positional:
        raise ValueError(f"no command to run in {args!r}")
    return positional[-1]


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(f"usage: {Path(sys.argv[0]).name} <command> [args...]\n")
        return 2

    name = measure_name(args)
    regression_dir = Path("regression")
    regression_dir.mkdir(parents=True, exist_ok=True)
    regression_file = regression_dir / f"{name}-duration.txt"

    # Resolve the baseline BEFORE running: a missing one fails fast, with the git command to restore
    # it, rather than after the wrapped run (which may be long). An empty string means the file is not
    # tracked yet, so this run writes the first version.
    try:
        baseline = ratchet.resolve(str(regression_file))
    except ratchet.BaselineMissing as missing:
        sys.stderr.write(f"{missing}\n")
        return 1

    # Tee the run's output: the developer still reads it live, and the copy is what gets measured.
    # A temp file rather than a second persistent log, so this needs no knowledge of where the
    # wrapped command keeps its own (`regression-of` already writes one) and cannot collide with it.
    with tempfile.TemporaryDirectory() as scratch:
        captured = Path(scratch) / "run.log"
        with open(captured, "w", encoding="utf-8") as log:
            process = subprocess.Popen(
                [os.environ.get("BAO_BASE_DIR", str(BIN_DIR.parent)) + "/run", *args],
                stdout=subprocess.PIPE,
                text=True,
                encoding="utf-8",
            )
            for line in process.stdout:
                sys.stdout.write(line)
                log.write(line)
            run_status = process.wait()

        extract = load(EXTRACT)
        extracted = extract.render(extract.parse_suites(captured.read_text(encoding="utf-8")))

    if not extracted:
        # A run with no test suites measures no durations; nothing to record or compare.
        return run_status

    try:
        verdict = ratchet.apply(str(regression_file), baseline, extracted, str(COMPARE))
    except ratchet.CompareFailed as failure:
        sys.stderr.write(failure.report)
        sys.stderr.write(f"compare-duration failed (exit {failure.code})\n")
        return failure.code

    # A failing run matters more than a duration change, so its status is the one that survives.
    if run_status != 0:
        return run_status
    if verdict.changed:
        sys.stderr.write(verdict.report)
        sys.stderr.write(
            f"\n{regression_file} changed. Review and stage it if the change is expected, or fix the cause.\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
