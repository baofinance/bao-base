#!/usr/bin/env python3
"""
Gas regression merge — the gas policy, applied by the shared compare module.

Usage: compare-gas.py <committed_file> <fresh_extracted_file>

`regression-of` finds this by name (compare-<type>.py) for the `gas` type. All the merge behaviour
— tolerance, ratchet, add/remove flagging, old-format migration, the emitted `# regression:` header
— lives in compare.py; this file exists to state the policy gas is measured against.
"""

import os
import sys

# Make sibling bin modules importable (matches the other bin scripts).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import compare  # noqa: E402

# Gas is measured in units where a few hundred is noise from an unrelated code motion but a
# fraction of a percent of a large function is not, so the absolute floor and the relative
# component are both meaningful. Values span several orders of magnitude across the report, hence
# scientific notation in the display column.
# Ratcheting: an improvement is ALWAYS flagged and locked in, however small. Flagging it is the
# point — that is what forces the win to be committed, so the baseline stays anchored at the best
# figure achieved and a later regression is measured from there rather than from a stale higher one.
# `better` says which direction counts as an improvement; it also labels every change in the report,
# so it matters whether or not the ratchet is on.
GAS_POLICY = {"better": "lower", "abs": 500.0, "rel": 0.001, "display": "{:.3e}", "ratchet": True}

if __name__ == "__main__":
    compare.main(GAS_POLICY, "Gas regression merge with per-row tolerance and ratchet")
