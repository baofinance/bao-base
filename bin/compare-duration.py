#!/usr/bin/env python3
"""
Duration regression merge - per-suite CPU compared by median-of-ratios.

Usage: compare-duration.py <committed_file> <fresh_extracted_file>

`regression-of` finds this by name for the `duration` measure, which every run that executes tests
produces alongside its own (see extract-duration.py). The file format and the emit-and-decide path
come from compare.py so every regression type describes itself the same way; the COMPARISON here is
what differs, and it is a well-worn one.

Storing each suite as a SHARE of the run total makes the values compositional: they sum to a
constant, so one suite changing shifts every other suite's share - Pearson's 1897 closure problem. A
single dominant regression then flags the whole innocent field around it. The fix is the RNA-seq
count-normalisation method (DESeq's median-of-ratios, edgeR's TMM), which faces the identical shape
- normalise out a global "library size" (here the machine's speed / the run's total cost) while a
few components genuinely change:

  - for each suite measurable in both runs, `ratio = fresh / committed`;
  - the machine scale = the MEDIAN of those ratios - robust, because the handful of suites that
    really changed are outliers the median ignores;
  - a suite flags when its ratio deviates from that scale by more than `suite_multiple` either way
    AND its absolute change exceeds `noise_seconds`. The absolute floor matters because a ratio is
    unreliable at small magnitudes: a 0.5s -> 0.1s wobble is a 5x ratio but 0.4s of scheduler noise,
    not a regression. Requiring both a relative AND an absolute change is the standard companion to
    median-of-ratios (DESeq's independent filtering) - do not test a ratio on a quantity too small.

So a uniformly faster or slower machine leaves every ratio at the scale and flags nothing, however
extreme; and one suite going 40x flags THAT suite and only that suite, because the median barely
moves. Absolute milliseconds are stored (machine-specific), yet detection is machine-independent,
because the scale is divided out at compare time, not baked into the file.

Two things this method genuinely cannot do, by construction, and does not pretend to:
  - tell "the whole run got slower" from "the machine got slower" - they are the same signal in
    relative terms. The scale MAGNITUDE is reported when it is large, as an honest note, but it never
    flags (that would fire on every real machine change).
  - work when MORE than half the suites change at once - then the "unchanged majority" the median
    leans on no longer exists. That is a re-baseline event, and the too-few-measurable note says so.
"""
import os
import statistics
import sys

# Make sibling bin modules importable (matches the other bin scripts).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import compare  # noqa: E402
import duration_format  # noqa: E402

SUITE_SECTION = duration_format.SUITE_SECTION

# The policy, in the same shape every regression type uses, so `compare.header_line` renders it in
# the same grammar. Units live in the key where a bare number would be ambiguous. ONE policy for every
# measure (test / gas / coverage): duration is a generalised BLOW-UP check, so it wants a coarse band
# that catches only extreme increases and tolerates moderate ones - not a per-environment tolerance
# coupling the tool to each run's determinism.
#   suite_multiple      a suite must deviate from the machine scale by more than this (either way) to
#                       flag. This is the "noise RATIO", set to the LOOSEST any measure needs: the
#                       random-seed, parallel `test`/`coverage` runs swing a suite up to ~6x run to run
#                       (measured: per-suite deviation-from-scale maxed at 6.09x over five runs), so 8x
#                       clears that noise. `gas` is deterministic and would tolerate a tighter band, but
#                       a blow-up check does not need one - a moderate gas increase is not a blow-up.
#                       Any "40x" is still caught at 8x.
#   run_shift_multiple  a whole-run scale beyond this is reported as a note - but never flags (a machine
#                       change is indistinguishable from a uniform slowdown in relative terms)
#   noise_seconds       a suite whose ABSOLUTE change is smaller than this is held however large its
#                       ratio: relative comparison is unreliable at small magnitudes. Set to EXCEED the
#                       largest overhead-dominated suite, so scheduler noise on it can never flag - a
#                       tiny suite (a `_sizes` contract-size test doing almost no work) is pure
#                       framework overhead, swinging as much as its own magnitude between runs. bao-base
#                       coverage suites top out near 1.1s and swing up to ~0.8s run to run (measured
#                       over several runs); 1.5s clears both. Any "40x" on a suite that matters is
#                       seconds of absolute change and still flags. This is the absolute half of "hold
#                       within EITHER bound", the standard companion to median-of-ratios (DESeq's
#                       independent filtering): do not test a ratio on a quantity too small to measure.
#   floor_seconds       a suite below this in a run gives no reliable ratio, so it is excluded from the
#                       median scale (kept low, 50ms, so the scale still rests on many suites).
DURATION_POLICY = {
    "suite_multiple": 8.0,
    "run_shift_multiple": 4.0,
    "noise_seconds": 1.5,
    "floor_seconds": 0.05,
}
# Report when FEWER than this many suites are measurable: a median over fewer than a handful can be
# swung by the couple that changed, so the machine scale is not trustworthy. It is an ABSOLUTE count,
# not a fraction of the run - a small project with a dozen measurable suites and many tiny ones below
# the floor has a perfectly good scale and must not be told otherwise. Not policy: it changes no
# verdict, only whether the run explains itself.
MIN_MEASURABLE = 5


def machine_scale(committed, fresh, floor_ms):
    """The robust per-run scale factor: the median of `fresh/committed` over suites measurable in both.

    Returns (scale, measurable_count). Suites below the floor in either run are excluded, because a
    ratio taken against scheduler noise is meaningless. With nothing measurable the scale is 1.0 (no
    evidence of a machine change), and every above-floor suite is then judged against that.
    """
    ratios = [
        fresh[name] / committed[name]
        for name in committed.keys() & fresh.keys()
        if committed[name] >= floor_ms and fresh[name] >= floor_ms
    ]
    return (statistics.median(ratios) if ratios else 1.0), len(ratios)


def merge(committed, fresh, scale, floor_ms, noise_ms):
    """Merge fresh onto committed per suite, judging each against the machine scale. Returns (merged, changes).

    Held suites keep their COMMITTED milliseconds, so the file is byte-stable run to run and only a
    genuine change rewrites a row. A suite is held when it appears/vanishes aside, it is held on
    EITHER ground: its absolute change is below the noise floor (too small to measure a ratio), OR it
    is measurable and its ratio tracks the machine scale within `suite_multiple`. It flags only when a
    change is BOTH large enough to matter AND deviates from the scale (or its committed value was
    sub-floor, so there is no reliable ratio and a significant change is a genuine appearance).
    """
    low = 1.0 / DURATION_POLICY["suite_multiple"]
    high = DURATION_POLICY["suite_multiple"]
    merged = {}
    changes = []  # (section, name, kind, old, new)
    for name in sorted(committed.keys() | fresh.keys()):
        old = committed.get(name)
        new = fresh.get(name)
        if old is None:
            merged[name] = new
            changes.append((SUITE_SECTION, name, "added", None, new))
        elif new is None:
            changes.append((SUITE_SECTION, name, "removed", old, None))
        elif abs(new - old) < noise_ms or (old >= floor_ms and low <= (new / old) / scale <= high):
            merged[name] = old  # too small a change to matter, or it tracks the machine scale: held
        else:
            merged[name] = new
            changes.append((SUITE_SECTION, name, "changed", old, new))
    return merged, changes


def main():
    committed_text, fresh_text = compare.read_pair("Duration regression merge: per-suite CPU by median-of-ratios")
    fresh = compare.parse_tables(fresh_text).get(SUITE_SECTION, {})
    if not fresh:
        # A run with no test suites (forge build --sizes) measures no durations at all, so there is
        # nothing to compare and nothing to write.
        sys.exit(0)

    committed = compare.parse_tables(committed_text).get(SUITE_SECTION, {})
    floor_ms = DURATION_POLICY["floor_seconds"] * duration_format.MILLISECONDS_PER_SECOND
    noise_ms = DURATION_POLICY["noise_seconds"] * duration_format.MILLISECONDS_PER_SECOND
    scale, measurable = machine_scale(committed, fresh, floor_ms)
    merged, changes = merge(committed, fresh, scale, floor_ms, noise_ms)

    decimals = duration_format.seconds_decimals(DURATION_POLICY["floor_seconds"])
    sections = [(SUITE_SECTION, duration_format.suite_frame(merged, decimals))]

    # Context and honest limits, to stderr, before the merge's own change lines. None of these change
    # the verdict - the exit code comes from the per-suite changes alone.
    if changes and measurable:
        sys.stderr.write(f"compared at machine scale {scale:.2f}x (median of {measurable} per-suite ratios)\n")
    if scale > DURATION_POLICY["run_shift_multiple"] or scale < 1.0 / DURATION_POLICY["run_shift_multiple"]:
        sys.stderr.write(
            f"the whole run is {scale:.2f}x the baseline - a machine or environment change, not flagged "
            f"(indistinguishable from a faster/slower machine in relative terms)\n"
        )
    if committed and measurable < MIN_MEASURABLE:
        sys.stderr.write(
            f"the machine scale rests on only {measurable} suite(s) above the {DURATION_POLICY['floor_seconds']:g}s "
            f"floor and may be unreliable\n"
        )

    sys.exit(compare.emit(DURATION_POLICY, sections, committed_text, changes))


if __name__ == "__main__":
    main()
