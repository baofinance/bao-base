#!/usr/bin/env python3
"""
Regression MERGE with per-row tolerance + ratchet (gas / coverage / sizes).

Usage: compare-gas.py <committed_file> <fresh_extracted_file>

Reads the committed baseline's `# regression:` header for the tolerances, direction and
display format (defaults if absent), then merges each (section, row) of the fresh extract
against the committed baseline and writes the merged file to stdout.

Per row, with `better=lower` (gas / sizes) — the tests invert for `better=higher` (coverage):
  - improvement (value moved to the better side): ALWAYS flag and lock in the new value (the
    ratchet — keeps the baseline anchored at the best, so within-tolerance creep can't hide a
    real regression measured from the best point);
  - regression beyond tolerance (Δ > abs OR Δ > rel·max): flag and lock in the new value;
  - regression within tolerance, or unchanged: hold the committed value (no churn);
  - a row present on only one side (added / removed): flag.
Only flagged rows differ from the committed baseline, so drift cannot accumulate across the
whole file the way a wholesale re-save did.

A baseline with no `# regression:` header is treated as an old-format file: it is reformatted into
the new format and its values are STILL compared (so a real change across the migration is flagged,
not silently accepted) — it fires a diff so you commit the migrated file, and never crashes on it.

Exit 1 if anything changed (regression, improvement, add, remove, or migration) so the run
fails until the merged file is committed; exit 0 when everything held. A summary goes to stderr.
"""
import argparse
import os
import re
import sys
from collections import OrderedDict

# Make sibling bin modules importable (matches the other bin scripts).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import forge_tables  # noqa: E402
import pandas as pd  # noqa: E402

DEFAULTS = {"better": "lower", "abs": 500.0, "rel": 0.001, "display": "{:.3e}"}
HEADER_RE = re.compile(r"^#\s*regression:\s*(.*)$", re.MULTILINE)


def parse_header(text):
    """Return the tolerance config from the file's `# regression:` header, defaults filled in."""
    cfg = dict(DEFAULTS)
    m = HEADER_RE.search(text)
    if m:
        for token in m.group(1).split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            if key in ("abs", "rel"):
                cfg[key] = float(value)
            elif key in ("better", "display"):
                cfg[key] = value
    return cfg


def parse_tables(text):
    """Parse a `path line + github table` file into OrderedDict[path -> OrderedDict[name -> value]].

    Tolerant of the old 2-column format (name | value) and the new 3-column one
    (name | value | display), with values in integer or scientific notation.
    """
    tables = OrderedDict()
    current = None
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if not s.startswith("|"):
            current = s  # a section / contract path line, e.g. src/X.sol:X
            tables.setdefault(current, OrderedDict())
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) < 2:
            continue
        name = cells[0]
        if name.lower() in ("function name", "contract", "file", "name") or set(name) <= set("-: "):
            continue  # header / separator row
        try:
            value = float(cells[1])
        except ValueError:
            continue
        if current is None:
            current = "(unknown)"
            tables.setdefault(current, OrderedDict())
        tables[current][name] = value
    return tables


def merge(committed, fresh, cfg):
    """Merge fresh onto committed per (path, name). Returns (merged, changes)."""
    better_lower = cfg["better"] == "lower"
    abs_tol, rel_tol = cfg["abs"], cfg["rel"]
    merged = OrderedDict()
    changes = []  # (path, name, kind, old, new)
    seen = set()

    for path, rows in fresh.items():
        committed_rows = committed.get(path, {})
        out = OrderedDict()
        for name, new in rows.items():
            seen.add((path, name))
            old = committed_rows.get(name)
            if old is None:
                out[name] = new
                changes.append((path, name, "added", None, new))
                continue
            if new == old:
                out[name] = old
                continue
            improved = (new < old) if better_lower else (new > old)
            delta = abs(new - old)
            held = delta <= abs_tol and delta <= rel_tol * max(abs(old), abs(new))
            if improved:
                out[name] = new  # ratchet: always lock in an improvement
                changes.append((path, name, "improved", old, new))
            elif held:
                out[name] = old  # within-tolerance regression: hold, no churn
            else:
                out[name] = new
                changes.append((path, name, "regressed", old, new))
        merged[path] = out

    for path, rows in committed.items():
        for name, old in rows.items():
            if (path, name) not in seen:
                changes.append((path, name, "removed", old, None))
    return merged, changes


def render(merged, cfg):
    """Render the merged tables as `header + path line + github table` with an exact and a display column."""
    fmt = cfg["display"]
    parts = [
        "# regression: better={better} abs={abs:g} rel={rel:g} display={display}".format(**cfg),
        "",  # blank line between the header and the first section
    ]
    first = True
    for path, rows in merged.items():
        frame = pd.DataFrame(
            [(name, int(round(value)), fmt.format(value)) for name, value in rows.items()],
            columns=["function name", "max", "display"],
        )
        if not first:
            parts.append("")
        first = False
        parts.append(path)
        parts.append(forge_tables.toStr(frame, floatfmt=".3e", intfmt=""))
    return "\n".join(parts) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Regression merge with per-row tolerance and ratchet")
    parser.add_argument("committed", help="committed baseline file (or '-' for stdin)")
    parser.add_argument("fresh", help="freshly extracted file")
    parser.add_argument("--abs-tolerance", type=float, default=None, help="override the header abs tolerance")
    parser.add_argument("--rel-tolerance", type=float, default=None, help="override the header rel tolerance")
    parser.add_argument("--better", default=None, choices=("lower", "higher"), help="override the header direction")
    args = parser.parse_args()

    committed_text = sys.stdin.read() if args.committed == "-" else open(args.committed).read()
    fresh_text = open(args.fresh).read()

    cfg = parse_header(committed_text)
    if args.abs_tolerance is not None:
        cfg["abs"] = args.abs_tolerance
    if args.rel_tolerance is not None:
        cfg["rel"] = args.rel_tolerance
    if args.better is not None:
        cfg["better"] = args.better

    migrating = HEADER_RE.search(committed_text) is None and committed_text.strip() != ""
    committed = parse_tables(committed_text)
    fresh = parse_tables(fresh_text)
    merged, changes = merge(committed, fresh, cfg)
    changed = bool(changes) or migrating

    sys.stdout.write(render(merged, cfg))
    if migrating:
        # A header-less (old-format) baseline is reformatted in place; its values are still compared, so a
        # real change across the migration is flagged rather than silently accepted.
        sys.stderr.write("format migrated to the new regression format — commit the result\n")
    for path, name, kind, old, new in changes:
        sys.stderr.write(f"{kind}: {path} :: {name}: {old} -> {new}\n")
    sys.exit(1 if changed else 0)


if __name__ == "__main__":
    main()
