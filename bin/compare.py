#!/usr/bin/env python3
"""
Shared regression MERGE: per-row tolerance + ratchet, driven by a caller-supplied policy.

Not a command in its own right — each regression type has a thin entry script (compare-gas.py,
compare-duration.py, …) that defines its policy and calls `main()`. `regression-of` looks up
`compare-<type>.py` by name and falls back to an exact text comparison when there is none, so a
type only gains tolerance behaviour by growing an entry script.

The policy — direction, tolerances, display format — belongs to the entry script, NOT to the data
file. The file's `# regression:` header is OUTPUT: it is re-emitted on every run to state the
policy that was actually applied. So a hand-edited header is overwritten rather than obeyed, and
because the emitted header lands in the consuming project's file, a policy change is still visible
in that project's diff. Since the policy lives in this shared repo, a change to it can move every
consumer's regression file with the reason recorded two repos away — `main()` therefore reports the
old and new header lines explicitly instead of silently re-emitting.

Nothing reads the header back: the comparison is on the header TEXT, so a value a committed header
merely omits cannot be mistaken for agreement. The header states every value the policy holds,
including any overridden from the command line, so a run made with a loosened tolerance produces a
visibly different header — and, being a change, one that has to be committed rather than passing
quietly.

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

Exit 1 if anything changed (regression, improvement, add, remove, migration, or policy change) so
the run fails until the merged file is committed; exit 0 when everything held. A summary goes to
stderr.
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

HEADER_RE = re.compile(r"^#\s*regression:\s*(.*)$", re.MULTILINE)
# `parse_tables` treats a first cell of "function name" as a heading, so the table round-trips.
GAS_COLUMNS = ("function name", "max", "display")


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
            if cfg["ratchet"] and improved:
                out[name] = new  # ratchet: always lock in an improvement
                changes.append((path, name, "improved", old, new))
            elif held:
                out[name] = old  # within-tolerance regression: hold, no churn
            else:
                out[name] = new
                # The label comes from the DIRECTION, not from which branch was taken: without a
                # ratchet an improvement beyond tolerance lands here too, and calling a halved gas
                # figure a regression would be plainly wrong.
                changes.append((path, name, "improved" if improved else "regressed", old, new))
        merged[path] = out

    for path, rows in committed.items():
        for name, old in rows.items():
            if (path, name) not in seen:
                changes.append((path, name, "removed", old, None))
    return merged, changes


def render_tables(sections):
    """Render `(section name, DataFrame)` pairs as `path line + github table` blocks.

    Only the block assembly is shared, because that is what `parse_tables` reads back — every
    regression type must produce the same structure, but each chooses its own columns beyond the
    first two. The first column must hold a heading `parse_tables` recognises (so the header row is
    not mistaken for data) and the second must hold the value the merge compares; anything after
    those is informational and is ignored on the way back in.

    The `# regression:` header is the caller's to prepend, since each type states its policy
    differently.
    """
    parts = []
    first = True
    for path, frame in sections:
        if not first:
            parts.append("")
        first = False
        parts.append(path)
        parts.append(forge_tables.toStr(frame, floatfmt=".3e", intfmt=""))
    return "\n".join(parts)


def header_line(policy):
    """The `# regression:` line stating the policy a run applied, as `key=value` for every key.

    Rendered from the policy dict rather than written per type, so every regression type states its
    policy in the same grammar and a reader (or a grep) can treat them alike. Put the unit in the
    KEY where a bare number would be ambiguous — `floor_seconds=0.05`, not `floor=0.05`.
    """

    def token(key, value):
        if isinstance(value, bool):  # before the number check: a bool IS an int in Python
            return f"{key}={'on' if value else 'off'}"
        if isinstance(value, (int, float)):
            return f"{key}={value:g}"
        return f"{key}={value}"

    return "# regression: " + " ".join(token(key, value) for key, value in policy.items())


def emit(policy, sections, committed_text, changes):
    """Write the merged file to stdout, report what moved to stderr, and return the exit code.

    Shared by every regression type: the header, the change detection and the exit-code meaning are
    part of the file's contract, not of any one type's policy. Keeping them here is what stops two
    types describing themselves differently — which is exactly what happened when duration built its
    own header string.
    """
    committed_header = HEADER_RE.search(committed_text)
    migrating = committed_header is None and committed_text.strip() != ""
    emitted = header_line(policy)
    # Compare the header TEXT, not parsed values: a key the committed header merely omits would
    # otherwise read as agreement while the emitted line is different.
    policy_changed = committed_header is not None and committed_header.group(0).strip() != emitted

    sys.stdout.write("\n".join([emitted, "", render_tables(sections)]) + "\n")

    if migrating:
        # A header-less (old-format) baseline is reformatted in place; its values are still compared,
        # so a real change across the migration is flagged rather than silently accepted.
        sys.stderr.write("format migrated to the new regression format - commit the result\n")
    if policy_changed:
        sys.stderr.write(f"policy changed:\n  was: {committed_header.group(0).strip()}\n  now: {emitted}\n")
    for path, name, kind, old, new in changes:
        sys.stderr.write(f"{kind}: {path} :: {name}: {old} -> {new}\n")
    return 1 if (changes or migrating or policy_changed) else 0


def read_pair(description):
    """Parse the two positional paths every compare entry point takes, and return their contents.

    The policy dict is the ONLY configuration surface — there are no command-line overrides, so an
    ad-hoc run cannot bake a non-standard policy into a committed baseline's header.
    """
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("committed", help="committed baseline file")
    parser.add_argument("fresh", help="freshly extracted file")
    args = parser.parse_args()
    return open(args.committed).read(), open(args.fresh).read()


def main(policy, description):
    """Entry point for the tolerance-and-ratchet merge, used by compare-gas.py."""
    committed_text, fresh_text = read_pair(description)
    merged, changes = merge(parse_tables(committed_text), parse_tables(fresh_text), policy)
    fmt = policy["display"]
    sections = [
        (
            path,
            pd.DataFrame(
                [(name, int(round(value)), fmt.format(value)) for name, value in rows.items()],
                columns=list(GAS_COLUMNS),
            ),
        )
        for path, rows in merged.items()
    ]
    sys.exit(emit(policy, sections, committed_text, changes))
