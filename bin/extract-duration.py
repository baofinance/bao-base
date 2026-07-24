#!/usr/bin/env python3
"""
Per-suite CPU time from a forge test log on stdin -> a regression table on stdout.

Duration is a DIMENSION of any run that executes tests, not a regression type of its own, so the
same extract serves the `test`, `gas` and `coverage` logs. (`sizes` runs `forge build --sizes`,
which has no suites at all, and yields no rows.)

Emits one absolute figure per suite: its CPU in milliseconds. The comparison (compare-duration.py)
divides out a robust per-run scale to stay machine-independent, so nothing is normalised here - the
raw measurement is what is stored, and coupling one suite to another via a shared total is exactly
what the median-of-ratios comparison avoids.

CPU time is read, never wall time. Wall carries the scheduling noise of parallel test execution -
the same suite measured 13.51s and 15.53s CPU across two runs while its wall time barely moved.
"""

import re
import sys

import duration_format

# Both code points render as "µ" and which one appears depends on the emitter, so accept either;
# forge itself writes U+00B5 MICRO SIGN. Spelled as escapes because the two are indistinguishable
# in a source file.
UNIT_SECONDS = {"s": 1.0, "ms": 1e-3, "µs": 1e-6, "μs": 1e-6}
# Longest first, so "ms" is never shadowed by the "s" alternative.
UNITS = "|".join(sorted((re.escape(unit) for unit in UNIT_SECONDS), key=len, reverse=True))

SUITE_NAME_RE = re.compile(r"^Ran \d+ tests? for (\S+)")
# The wall time comes first and CPU is the parenthesised one - capture only the latter. Requiring
# the "Suite result:" prefix is also what keeps the solc compile line ("Solc 0.8.30 finished in
# 155.04s") and the closing run summary from being counted as suites.
SUITE_CPU_RE = re.compile(rf"^Suite result:.*finished in [\d.]+(?:{UNITS}) \(([\d.]+)({UNITS}) CPU time\)")

# Raw extracts are transient (the comparison reads only the milliseconds column), so the display
# precision here is a fixed readable default rather than the policy floor, which lives in the compare.
DISPLAY_DECIMALS = 2


def parse_suites(log_text: str) -> list[tuple[str, float]]:
    """Pair each `Ran N tests for <suite>` line with the CPU seconds on its later `Suite result:` line.

    The two are separated by the suite's per-test lines, so the name is carried forward until the
    result that closes it.
    """
    suites: list[tuple[str, float]] = []
    pending: str | None = None
    for line in log_text.splitlines():
        name = SUITE_NAME_RE.match(line)
        if name:
            pending = name.group(1)
            continue
        result = SUITE_CPU_RE.match(line)
        if result and pending is not None:
            suites.append((pending, float(result.group(1)) * UNIT_SECONDS[result.group(2)]))
            pending = None
    return suites


def render(suites: list[tuple[str, float]]) -> str:
    """Render the per-suite section, or nothing when no suites ran (the `sizes` build case)."""
    if not suites:
        return ""
    milliseconds = {name: seconds * duration_format.MILLISECONDS_PER_SECOND for name, seconds in suites}
    return duration_format.suite_table(milliseconds, DISPLAY_DECIMALS) + "\n"


if __name__ == "__main__":
    # The logs carry "µs", so decode and encode explicitly rather than inheriting a locale that
    # might not be UTF-8.
    sys.stdin.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    sys.stdout.write(render(parse_suites(sys.stdin.read())))
