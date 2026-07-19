#!/usr/bin/env python3
"""Report how long each test takes, slowest first.

Forge only exposes a PER-TEST duration through `--json` (`--summary` reports pass/fail counts, and the per-test
lines carry gas, not time), so this runs the suite that way and renders the timings itself. It measures the same
set as `run test` - script/**/*.t.sol excluded - so the numbers describe the suite you actually run.

Extra arguments are passed through to forge, so a slow area can be isolated:
    run test-duration --match-path 'test/reward/**'
    run test-duration --top 40

Timings are wall-clock and therefore load-dependent; treat them as "what is heavy", not as exact figures. Fuzz
tests dominate, and their cost moves with --fuzz-runs.
"""
import argparse
import json
import re
import subprocess
import sys

# forge prints a duration as a run of magnitude-ordered parts, e.g. "1s 234ms 567µs".
_UNIT_MS = {"ns": 1e-6, "µs": 1e-3, "us": 1e-3, "ms": 1.0, "s": 1e3, "m": 6e4, "h": 3.6e6}
_PART = re.compile(r"([\d.]+)\s*(ns|µs|us|ms|s|m|h)")


def duration_ms(text):
    """Total milliseconds for a forge duration string; 0.0 when it is missing or unparseable."""
    return sum(float(value) * _UNIT_MS[unit] for value, unit in _PART.findall(text or ""))


def main(argv):
    parser = argparse.ArgumentParser(description="Report test durations, slowest first.")
    parser.add_argument("--top", type=int, default=25, help="how many of the slowest tests to list (default 25)")
    args, forge_args = parser.parse_known_args(argv)

    # --nmp matches `bin/test`, so this measures the same suite. Failures are still reported below rather than
    # aborting, since a failing run's timings are exactly when they are most wanted.
    command = ["forge", "test", "--json", "--nmp", "script/**/*.t.sol", *forge_args]
    completed = subprocess.run(command, capture_output=True, text=True)

    try:
        suites = json.loads(completed.stdout)
    except json.JSONDecodeError:
        # No JSON means forge never got as far as running tests (a build failure, a bad argument).
        sys.stderr.write(completed.stderr or completed.stdout)
        return completed.returncode or 1

    rows = []
    failures = []
    skipped = 0
    for suite_id, suite in suites.items():
        suite_name = suite_id.split(":")[-1]
        for test_name, result in (suite.get("test_results") or {}).items():
            short_name = test_name.split("(")[0]
            # forge reports "Success", "Failure" or "Skipped". Test the FAILURE case explicitly - treating
            # anything that is not "Success" as failed reports skipped tests as failures.
            status = result.get("status")
            if status == "Skipped":
                skipped += 1
            elif status != "Success":
                # Name them: "N FAILED" alone leaves you re-running the suite just to find out which.
                failures.append(f"{suite_name}.{short_name}: {result.get('reason') or 'no reason reported'}")
            rows.append((duration_ms(result.get("duration")), suite_name, short_name))

    if not rows:
        print("no tests ran")
        return completed.returncode

    rows.sort(reverse=True)
    width = max(len(f"{row[0]:.1f}") for row in rows[: args.top])
    print(f"{'ms':>{width}}  test")
    for milliseconds, suite_name, test_name in rows[: args.top]:
        print(f"{milliseconds:{width}.1f}  {suite_name}.{test_name}")

    total = sum(row[0] for row in rows)
    tally = f"{total:{width}.1f}  TOTAL over {len(rows)} tests"
    if failures:
        tally += f", {len(failures)} FAILED"
    if skipped:
        tally += f", {skipped} skipped"
    print(tally)
    for failure in failures:
        print(f"  FAILED  {failure}")
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
