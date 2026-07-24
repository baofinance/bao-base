"""
The duration regression file format, shared by the extract that writes it and the compare that reads it.

Both sides must agree on the section name, the stored unit, and the display precision, so a change
moves them together instead of drifting apart. This lives in its own module because neither
`extract-duration.py` nor `compare-duration.py` can import the other - a hyphen is not a valid module
name - so the contract between them needs a home that both can reach.

One section, one stored value per suite: its ABSOLUTE CPU in milliseconds. The comparison is
machine-independent NOT by storing a share of the run (which couples every suite to every other -
one suite changing shifts them all), but by dividing out a robust per-run scale at compare time (see
compare-duration.py). Absolute milliseconds - not seconds - because a small suite (bao-base's whole
run is about a second) would round to 1 in whole seconds, leaving no resolution to compare.
"""

import math

import forge_tables
import pandas as pd

SUITE_SECTION = "suite CPU (milliseconds)"
MILLISECONDS_PER_SECOND = 1000


def seconds_decimals(floor_seconds):
    """How many decimals of a seconds figure the floor can actually act on.

    Showing more precision than the floor can distinguish is noise: a 0.5s floor justifies one
    decimal, 0.05s two. Derived from the floor so the display precision and the floor cannot drift.
    """
    return max(0, math.ceil(-math.log10(floor_seconds)))


def suite_frame(name_to_milliseconds, decimals):
    """The one suite section as a DataFrame: `name | milliseconds | CPU`, sorted by name.

    Column 2 is the stored value the comparison reads; column 3 is the same figure in seconds for a
    human, at `decimals` places. Sorted by name because forge emits suites in completion order, which
    varies between runs, so name order is what makes two baselines diffable side by side. The unit is
    carried in the CPU cell so each figure is self-describing and the table renderer does not re-parse
    it as a number.

    A DataFrame (not a string) so the comparison can hand it to `compare.render_tables` alongside the
    section name, exactly as every regression type renders its tables; `suite_table` wraps it for the
    extract, which writes the section directly.
    """
    return pd.DataFrame(
        [
            (name, int(round(ms)), f"{ms / MILLISECONDS_PER_SECOND:.{decimals}f}s")
            for name, ms in sorted(name_to_milliseconds.items())
        ],
        columns=["name", "milliseconds", "CPU"],
    )


def suite_table(name_to_milliseconds, decimals):
    """The suite section as a ready-to-write string (`SUITE_SECTION` + table), for the extract."""
    return (
        SUITE_SECTION
        + "\n"
        + forge_tables.toStr(suite_frame(name_to_milliseconds, decimals), floatfmt=".3e", intfmt="")
    )
