#!/usr/bin/env python3
"""
Per-suite CPU time from a forge test log on stdin -> a regression table on stdout.

Duration is a DIMENSION of any run that executes tests, not a regression type of its own, so the
same extract serves the `test`, `gas` and `coverage` logs. (`sizes` runs `forge build --sizes`,
which has no suites at all, and yields no rows.)

Two sections, because the two halves of the check need different measures:
  - each suite's share of the run's total CPU, in parts per billion. A share is machine-INDEPENDENT,
    so one committed baseline holds across machines, and parts per billion keeps it a whole number —
    the regression table stores integers, so a raw fraction would be rounded away entirely.
  - the run's total CPU in MILLISECONDS, taken as the SUM of the per-suite figures. Machine-
    DEPENDENT by design: it is the only thing that moves when a change slows every suite equally,
    which leaves every share exactly where it was. Milliseconds rather than seconds because a small
    suite — bao-base's whole run is about a second — rounds to 1 in whole seconds, leaving nothing to
    compare and making the per-suite floor derived from it half of the entire run.

That total is a COMPARABLE INDEX, not a measure of resource consumed — do not read it as
"CPU-seconds used". On one run of the harbor suite it records 681s while `time` puts the whole
process tree at 527s (490s user + 37s sys), so the parts exceed the whole by 1.29×: forge's
per-suite figure evidently counts more than one thread's work within a suite. That costs nothing
here, because both sides of a comparison use the same measure and the shares normalise it away —
but it does mean the number is only meaningful against another number from this same extract.

Forge's own closing summary is a different figure again — 8149.18s against a per-suite sum of 4040s
for the same run — and is deliberately not used. It divides by that run's 827.65s wall time to give
9.85, the worker count, so it is elapsed time across all parallel workers INCLUDING THEIR IDLE.
Using it would reintroduce the scheduling sensitivity that reading CPU time exists to avoid, and it
would not share a denominator with the shares above.

Two consecutive runs of the same unchanged suite recorded 616s and 681s, about 10% apart, which is
why the total is compared against a wide multiplier rather than a tight bound.

CPU time is read, never wall time. Wall carries the scheduling noise of parallel test execution —
the same suite measured 13.51s and 15.53s CPU across two runs while its wall time barely moved.
"""
import re
import sys

import duration_format
import forge_tables
import pandas as pd

# Both code points render as "µ" and which one appears depends on the emitter, so accept either;
# forge itself writes U+00B5 MICRO SIGN. Spelled as escapes because the two are indistinguishable
# in a source file.
UNIT_SECONDS = {"s": 1.0, "ms": 1e-3, "µs": 1e-6, "μs": 1e-6}
# Longest first, so "ms" is never shadowed by the "s" alternative.
UNITS = "|".join(sorted((re.escape(unit) for unit in UNIT_SECONDS), key=len, reverse=True))

SUITE_NAME_RE = re.compile(r"^Ran \d+ tests? for (\S+)")
# The wall time comes first and CPU is the parenthesised one — capture only the latter. Requiring
# the "Suite result:" prefix is also what keeps the solc compile line ("Solc 0.8.30 finished in
# 155.04s") and the closing run summary from being counted as suites.
SUITE_CPU_RE = re.compile(rf"^Suite result:.*finished in [\d.]+(?:{UNITS}) \(([\d.]+)({UNITS}) CPU time\)")

SHARE_PRECISION = duration_format.SHARE_PRECISION
SHARE_SECTION = duration_format.SHARE_SECTION
TOTAL_SECTION = duration_format.TOTAL_SECTION


def parse_suites(log_text: str) -> list[tuple[str, float]]:
    """Pair each `Ran N tests for <suite>` line with the CPU time on its later `Suite result:` line.

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
    """Render the two sections in the regression table format, or nothing when no suites ran."""
    if not suites:
        return ""
    total = sum(value for _, value in suites)
    shares = pd.DataFrame(
        [(name, round(value / total * SHARE_PRECISION)) for name, value in suites],
        columns=["name", "share"],
    )
    run_total = pd.DataFrame(
        [(duration_format.TOTAL_ROW, round(total * duration_format.MILLISECONDS_PER_SECOND))],
        columns=["name", "milliseconds"],
    )
    return (
        "\n".join(
            [
                SHARE_SECTION,
                forge_tables.toStr(shares, floatfmt=".3e", intfmt=""),
                "",
                TOTAL_SECTION,
                forge_tables.toStr(run_total, floatfmt=".3e", intfmt=""),
            ]
        )
        + "\n"
    )


if __name__ == "__main__":
    # The logs carry "µs", so decode and encode explicitly rather than inheriting a locale that
    # might not be UTF-8.
    sys.stdin.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    sys.stdout.write(render(parse_suites(sys.stdin.read())))
