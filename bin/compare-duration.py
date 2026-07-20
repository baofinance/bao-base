#!/usr/bin/env python3
"""
Duration regression merge — CPU time compared at two granularities.

Usage: compare-duration.py <committed_file> <fresh_extracted_file>

`regression-of` finds this by name for the `duration` measure, which every run that executes tests
produces alongside its own (see extract-duration.py). Table parsing and rendering come from
compare.py so the file format stays identical across regression types; the POLICY here differs from
gas's in three ways, which is why this is a separate merge rather than gas's with other numbers:

  - **Two granularities, checked separately.** Per suite, its SHARE of run CPU — machine-independent,
    so one committed baseline holds on any machine, and it catches a suite that got worse relative to
    its peers. Per run, the TOTAL CPU in seconds — machine-dependent on purpose, because it is the
    only thing that moves when a change slows every suite equally and leaves every share untouched.
    Neither alone is sufficient and no boolean combination of the two per row works: requiring both
    to fire misses the uniform slowdown, and requiring either fires on every machine change.
  - **Hold within EITHER bound, not both.** The absolute bound is therefore a noise floor: a suite
    too small to measure can double without flagging. Gas holds only within BOTH, which is right for
    a deterministic quantity but would make every tiny suite a false alarm here.
  - **No ratchet.** Gas locks in every improvement, keeping the baseline at the best value ever seen.
    Doing that with timings would anchor each suite at its fastest run on an idle machine, so a
    change is judged symmetrically: a small improvement is held like any other small change.
"""
import math
import os
import sys
from collections import OrderedDict

# Make sibling bin modules importable (matches the other bin scripts).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import compare  # noqa: E402
import duration_format  # noqa: E402
import pandas as pd  # noqa: E402

SHARE_SECTION = duration_format.SHARE_SECTION
TOTAL_SECTION = duration_format.TOTAL_SECTION
SHARE_PRECISION = duration_format.SHARE_PRECISION

# The policy, in the same shape every regression type uses, so `compare.header_line` renders it in
# the same grammar. Units live in the key where a bare number would be ambiguous.
#   shares_multiple  a suite must MORE than double its share of the run before it flags
#   total_multiple   the run total moves with the machine too, so it needs more room
#   floor_seconds    below this a suite's timing is scheduler jitter rather than signal. It has to
#                    stay well under the whole run or it swallows every row: at 0.5s over bao-base's
#                    ~1s suite no row could ever flag. Measured jitter was ~15% on a 13.5s suite, so
#                    50ms is comfortably above the noise.
#   ratchet          off: a change is judged symmetrically, so a small improvement is held rather
#                    than anchoring every suite at its fastest run on an idle machine.
DURATION_POLICY = {
    "shares_multiple": 2.0,
    "total_multiple": 4.0,
    "floor_seconds": 0.05,
    "ratchet": False,
}

# Report when this fraction of the suites sit under the floor: past that the share check is mostly
# inert, and a check that cannot fire must say so rather than pass quietly. Not policy — it changes
# no verdict, only whether the run explains itself.
INERT_FRACTION = 0.5



def relative_bound(multiplier):
    """The `rel` tolerance that triggers when a value changes by `multiplier` times.

    A change flags when `delta > rel * max(old, new)`; at exactly `multiplier` times,
    `delta = (multiplier - 1) * old` and `max = multiplier * old`, which solves to `(n - 1) / n`.
    Note the bound approaches but never reaches 1: `rel = 1` would hold ANY increase, however large.
    """
    return (multiplier - 1) / multiplier


def seconds_decimals(floor_seconds):
    """How many decimals of a seconds figure the floor can actually act on.

    Showing more precision than the tolerance can distinguish is noise: a 0.5s floor justifies one
    decimal, 0.05s justifies two. Derived from the floor so the two cannot drift apart.
    """
    return max(0, math.ceil(-math.log10(floor_seconds)))


def _by_cost(rows):
    """Rows heaviest first, ties broken by name so the rank is stable between identical runs."""
    return sorted(rows.items(), key=lambda row: (-row[1], row[0]))


def render_sections(merged, total_milliseconds):
    """Build the display tables: the stored value, plus what it means in seconds and as a percentage.

    Both extra columns are DERIVED from the share and the run total already in the file — nothing
    further is recorded, so the baseline stays machine-independent. The seconds column is what the
    absolute floor acts on and the percentage is what the multiplier acts on, so between them they
    show how each tolerance will judge the row.
    """
    decimals = seconds_decimals(DURATION_POLICY["floor_seconds"])
    sections = []
    for path, rows in merged.items():
        # The unit is carried in the cell rather than only in the heading: it keeps each figure
        # self-describing, and it stops the table renderer re-parsing these as numbers and
        # reformatting them back into scientific notation.
        if path == TOTAL_SECTION:
            frame = pd.DataFrame(
                [
                    (name, int(round(value)), f"{value / duration_format.MILLISECONDS_PER_SECOND:.{decimals}f}s")
                    for name, value in rows.items()
                ],
                columns=["name", "milliseconds", "CPU"],
            )
        else:
            seconds_per_part = total_milliseconds / duration_format.MILLISECONDS_PER_SECOND / SHARE_PRECISION
            # Rank by cost, but LIST by name. Forge emits suites in completion order, which varies
            # between runs, so sorting by name is what makes two baselines diffable side by side —
            # and the rank then carries the information that ordering by cost would have given.
            rank_of = {name: position for position, (name, _) in enumerate(_by_cost(rows), start=1)}
            frame = pd.DataFrame(
                [
                    (
                        name,
                        int(round(value)),
                        f"{value * seconds_per_part:.{decimals}f}s",
                        f"{value / SHARE_PRECISION:.2%}",
                        rank_of[name],
                    )
                    for name, value in sorted(rows.items())
                ],
                columns=["name", "parts per billion", "CPU", "share", "rank"],
            )
        sections.append((path, frame))
    return sections


def share_floor(fresh):
    """The share below which a suite's timing is noise, in parts per billion of the run measured.

    Derived from this run's own total rather than fixed, so the floor stays worth the same half
    second whatever the run costs.
    """
    total_seconds = run_total_milliseconds(fresh) / duration_format.MILLISECONDS_PER_SECOND
    return DURATION_POLICY["floor_seconds"] / total_seconds * duration_format.SHARE_PRECISION


def run_total_milliseconds(tables):
    """The run's total CPU, which sizes the floor and converts shares back into seconds."""
    totals = tables.get(TOTAL_SECTION)
    if not totals:
        raise ValueError(f"the extract has no {TOTAL_SECTION!r} section, so the noise floor cannot be sized")
    return next(iter(totals.values()))


def merge(committed, fresh):
    """Merge fresh onto committed per (section, row), symmetrically and without a ratchet."""
    tolerances = {
        SHARE_SECTION: (share_floor(fresh), relative_bound(DURATION_POLICY["shares_multiple"])),
        # The total is absolute seconds, so it has no meaningful floor - the multiplier governs.
        TOTAL_SECTION: (0.0, relative_bound(DURATION_POLICY["total_multiple"])),
    }
    merged = OrderedDict()
    changes = []  # (path, name, kind, old, new)
    seen = set()

    for path, rows in fresh.items():
        abs_tol, rel_tol = tolerances[path]
        committed_rows = committed.get(path, {})
        out = OrderedDict()
        for name, new in rows.items():
            seen.add((path, name))
            old = committed_rows.get(name)
            if old is None:
                out[name] = new
                changes.append((path, name, "added", None, new))
                continue
            delta = abs(new - old)
            if delta <= abs_tol or delta <= rel_tol * max(abs(old), abs(new)):
                out[name] = old  # within tolerance: hold the committed value, no churn
            else:
                out[name] = new
                changes.append((path, name, "changed", old, new))
        merged[path] = out

    for path, rows in committed.items():
        for name, old in rows.items():
            if (path, name) not in seen:
                changes.append((path, name, "removed", old, None))
    return merged, changes


def main():
    committed_text, fresh_text = compare.read_pair(
        "Duration regression merge: per-suite share and run total CPU"
    )
    fresh = compare.parse_tables(fresh_text)
    if not fresh:
        # A run with no test suites (forge build --sizes) measures no durations at all, so there is
        # nothing to compare and nothing to write.
        sys.exit(0)

    merged, changes = merge(compare.parse_tables(committed_text), fresh)
    sections = render_sections(merged, run_total_milliseconds(fresh))

    # A floor that covers most of the run leaves the share check unable to fire for those rows. Say
    # so: a check that cannot discriminate must not be reported as a clean pass. Written before the
    # merge report so it frames what follows.
    floor = share_floor(fresh)
    suites = fresh.get(SHARE_SECTION, {})
    inert = [name for name, value in suites.items() if value <= floor]
    if suites and len(inert) > INERT_FRACTION * len(suites):
        sys.stderr.write(
            f"{len(inert)} of {len(suites)} suites are below the {DURATION_POLICY['floor_seconds']:g}s "
            f"floor and cannot flag however much they change - this run is too short for the share "
            f"check to say much\n"
        )

    sys.exit(compare.emit(DURATION_POLICY, sections, committed_text, changes))


if __name__ == "__main__":
    main()
