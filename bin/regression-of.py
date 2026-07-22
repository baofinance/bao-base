#!/usr/bin/env python3
"""
Check one run's regression metric against the committed baseline, and update it only on a change.

`regression-of <type> [args...]` runs `<type>` (gas, coverage, sizes, ...), extracts the type's metric
from the run's output, and compares it against the baseline in `regression/<type>.txt`:
  regression-of gas       -> regression/gas.txt      (tolerance/ratchet merge via compare-gas.py)
  regression-of coverage  -> regression/coverage.txt  (exact-match: any difference is a change)
  regression-of sizes     -> regression/sizes.txt

The baseline read, the compare, and the write-only-on-change decision live in the shared `ratchet`
module, so this and `duration-of` do not each re-implement them. A missing baseline is not silently
regenerated: `ratchet.resolve` offers the git command that restores it.

The inner command runs as a SUBPROCESS, not sourced. That is load-bearing: `run` dispatches bash
scripts by sourcing them, so a wrapper that sourced its inner command would share its shell and be
terminated by the inner `exit`. Being a Python script makes that structural (it cannot be sourced) and
lets it import `ratchet` directly rather than bridging bash to Python.
"""

import os
import subprocess
import sys
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN_DIR))

import ratchet  # noqa: E402 - importable only after bin is on the path above


def _info1(message: str) -> None:
    """A progress line shown only at raised verbosity, mirroring the bash `info1` (INFO level 1)."""
    if int(os.environ.get("BAO_BASE_VERBOSITY") or "0") >= 1:
        sys.stderr.write(message + "\n")


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(f"usage: {Path(sys.argv[0]).name} <type> [args...]\n")
        return 2

    regression_type = args[0]
    extra_args = args[1:]
    regression_dir = Path("regression")
    regression_dir.mkdir(parents=True, exist_ok=True)
    regression_file = regression_dir / f"{regression_type}.txt"
    generated_log = regression_dir / f"{regression_type}.log"

    # Resolve the baseline BEFORE the run: a missing one fails fast (with the git command to restore
    # it) rather than after the often-long run. An empty string means the file is not tracked yet, so
    # this run writes the first version.
    try:
        baseline = ratchet.resolve(str(regression_file))
    except ratchet.BaselineMissing as missing:
        sys.stderr.write(f"{missing}\n")
        return 1

    # Run `<type> [args...]` via the dispatcher, teeing its output to the log AND the console (the
    # developer reads it live). A subprocess, not sourced - see the module note.
    _info1(f"generating regression for {regression_type}...")
    with open(generated_log, "w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [os.environ.get("BAO_BASE_DIR", str(BIN_DIR.parent)) + "/run", regression_type, *extra_args],
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        for line in process.stdout:
            sys.stdout.write(line)
            log.write(line)
        run_status = process.wait()
    if run_status != 0:
        sys.stderr.write(
            f"{regression_type} failed (exit code {run_status}). "
            f"Fix the failing tests before running regression.\n"
        )
        return 1

    # Extract the type's metric. `extract-<type>.py` reads the log on stdin and writes the extracted
    # values on stdout (one CLI contract for every type); a type with no extract script uses the raw
    # log as its own extract.
    extract_script = BIN_DIR / f"extract-{regression_type}.py"
    log_text = generated_log.read_text(encoding="utf-8")
    if extract_script.exists():
        extraction = subprocess.run(
            [sys.executable, str(extract_script)], input=log_text, capture_output=True, text=True
        )
        if extraction.returncode != 0:
            sys.stderr.write(extraction.stderr)
            sys.stderr.write(
                f"extract-{regression_type} failed (exit {extraction.returncode}). "
                f"Fix the extract before running regression.\n"
            )
            return extraction.returncode
        extracted = extraction.stdout
    else:
        extracted = log_text

    # Compare against the baseline and update the file only on a change. gas has a compare script
    # (tolerance/ratchet); coverage and sizes have none, so any difference is a change.
    _info1(f"checking {regression_type} against {regression_file}...")
    compare_script = BIN_DIR / f"compare-{regression_type}.py"
    try:
        verdict = ratchet.apply(
            str(regression_file),
            baseline,
            extracted,
            str(compare_script) if compare_script.exists() else None,
        )
    except ratchet.CompareFailed as failure:
        sys.stderr.write(failure.report)
        sys.stderr.write(
            f"compare-{regression_type} failed (exit {failure.code}). "
            f"Fix the merge before running regression.\n"
        )
        return failure.code

    if verdict.changed:
        sys.stderr.write(
            f"The regression file {regression_file} changed:\n{verdict.report}\n\n"
            f"Review and commit {regression_file} if the change is expected, or fix the cause.\n"
        )
        return 1
    sys.stderr.write(f"No changes detected in {regression_file}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
