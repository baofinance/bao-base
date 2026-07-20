"""
The duration regression file format, shared by the extract that writes it and the compare that reads it.

Both sides must agree on the section names and the share scale, so a change moves them together
instead of drifting apart. This lives in its own module because neither `extract-duration.py` nor
`compare-duration.py` can import the other — a hyphen is not a valid module name — so the contract
between them needs a home that both can reach.
"""

SHARE_PRECISION = 1_000_000_000  # parts per billion
SHARE_SECTION = "suite share of run CPU (parts per billion)"
# Milliseconds, not seconds: a small suite (bao-base's whole run is about a second) rounds to 1 in
# whole seconds, which leaves no resolution to compare against and makes the derived per-suite floor
# half the entire run.
TOTAL_SECTION = "run total CPU (milliseconds)"
TOTAL_ROW = "all suites"
MILLISECONDS_PER_SECOND = 1000
