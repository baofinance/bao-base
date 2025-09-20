#!/usr/bin/env python3
"""
Gas regression comparison with numerical tolerance.
Handles gas report format: | function name | gas value |
Accepts colored git diff input and preserves colors in output.
"""
import argparse
import math
import os
import re
import sys
from typing import Optional, Tuple

# Add the bin directory to path for imports
sys.path.insert(0, os.path.dirname(__file__))

# Default gas comparison tolerance values
DEFAULT_GAS_TOLERANCE_REL = 0.01  # 1% relative tolerance
DEFAULT_GAS_TOLERANCE_ABS = 10  # 10 gas absolute tolerance


def strip_ansi_codes(text: str) -> str:
    """Remove ANSI color codes from text."""
    ansi_escape = re.compile(r"\x1b\[[0-9;]*m")
    return ansi_escape.sub("", text)


def parse_gas_line(line: str) -> Optional[Tuple[str, float]]:
    """
    Parse a gas report line in the format: | function name | gas value |
    Returns (function_name, gas_value) or None if not a valid gas line.
    Strips ANSI codes before parsing.
    Handles git diff prefixes (-, +) before the table format.
    Handles leading whitespace before diff prefixes.
    """
    # Strip ANSI codes for parsing
    clean_line = strip_ansi_codes(line)

    # First strip all leading whitespace
    clean_line = clean_line.lstrip()

    # Remove git diff prefixes (-, +) if present at the beginning of the line
    clean_line = re.sub(r"^[+-]", "", clean_line)

    # Again strip any whitespace that may have been between the diff prefix and the table
    clean_line = clean_line.lstrip()

    # Match gas report table format: | function_name | number |
    pattern = r"^\|\s*([^|]+?)\s*\|\s*(\d+(?:\.\d+)?(?:e[+-]?\d+)?)\s*\|"
    match = re.match(pattern, clean_line)

    if not match:
        return None

    function_name = match.group(1).strip()
    try:
        gas_value = float(match.group(2))
        return (function_name, gas_value)
    except ValueError:
        return None


def compare_gas_lines(old_line: str, new_line: str, rel_tol: float, abs_tol: float) -> bool:
    """
    Compare two gas report lines.
    Returns True if differences exceed tolerance (should be kept).
    """
    # Parse both lines (strips colors automatically)
    old_parsed = parse_gas_line(old_line)
    new_parsed = parse_gas_line(new_line)

    # If either line is not a gas line, treat as structural change
    if old_parsed is None or new_parsed is None:
        return True

    old_func, old_gas = old_parsed
    new_func, new_gas = new_parsed

    # If function names differ, it's a structural change
    if old_func != new_func:
        return True

    # Compare gas values using math.isclose
    # Use both relative and absolute tolerance (OR logic):
    # within tolerance if either relative OR absolute threshold is satisfied.
    if not math.isclose(old_gas, new_gas, rel_tol=rel_tol, abs_tol=abs_tol):
        return True  # Difference exceeds tolerance

    return False  # Within tolerance


def _is_context_line(line: str) -> bool:
    """A context line starts with a space and is not a +/- diff line."""
    if not line:
        return False
    if not line.startswith(" "):
        return False
    # not a colored +/- or plain +/- gas row
    if re.search(r"(^|\s)\x1b\[31m-", line) or re.search(r"(^|\s)-\|", line) or re.search(r"(^|\s)-", line):
        return False
    if re.search(r"(^|\s)\x1b\[32m\+", line) or re.search(r"(^|\s)\+\|", line) or re.search(r"(^|\s)\+", line):
        return False
    return True


def _is_minus(line: str) -> bool:
    return bool(
        re.search(r"(^|\s)\x1b\[31m-", line)
        or re.search(r"(^|\s)-\|", line)
        or (line.lstrip().startswith("-") and not line.lstrip().startswith("---"))
    )


def _is_plus(line: str) -> bool:
    return bool(
        re.search(r"(^|\s)\x1b\[32m\+", line)
        or re.search(r"(^|\s)\+\|", line)
        or (line.lstrip().startswith("+") and not line.lstrip().startswith("+++"))
    )


def filter_colored_diff_lines(diff_lines: list[str], rel_tol: float, abs_tol: float) -> tuple[list[str], bool]:
    """
    Filter colored git diff lines.
    - Always preserve context lines.
    - For paired +/- data rows (same function):
        * Exceeds tolerance -> keep both (old red, new green)
        * Within tolerance  -> replace the pair with a single line derived from the '+' line,
                               where the first '+' is replaced by a space ' ' (colors preserved),
                               and emit it at the position of the old '-' line.
    - For NON-DATA rows (e.g., headers/separators, anything not matching | name | number |):
        * Treat like context: pass through '-...' as-is.
        * If a '+...' of the same normalized content and equal length also appears in the chunk,
          drop the '+...' one to avoid duplication; otherwise keep both.
    - For structural changes (singletons or name mismatch), keep lines and mark exceeding.
    Returns: (lines_to_print, has_exceed)
    """
    filtered_lines: list[str] = []
    has_exceed = False
    i = 0

    while i < len(diff_lines):
        line = diff_lines[i].rstrip()

        # Keep context lines
        if _is_context_line(line):
            filtered_lines.append(line)
            i += 1
            continue

        # Collect a contiguous +/- chunk
        if _is_minus(line) or _is_plus(line):
            chunk: list[tuple[int, str]] = []
            j = i
            while j < len(diff_lines):
                l = diff_lines[j].rstrip()
                if _is_minus(l) or _is_plus(l):
                    chunk.append((j, l))
                    j += 1
                    continue
                break

            # Build structures
            minus_map: dict[str, tuple[int, str]] = {}  # data rows keyed by function name
            plus_map: dict[str, tuple[int, str]] = {}

            # Non-data rows grouped by normalized content (strip ANSI, strip +/- and leading spaces)
            nd_minus: dict[str, list[tuple[int, str, int]]] = {}
            nd_plus: dict[str, list[tuple[int, str, int]]] = {}

            for idx, l in chunk:
                parsed = parse_gas_line(l)
                if parsed is not None:
                    # Data rows
                    func_name = parsed[0]
                    if _is_minus(l):
                        minus_map[func_name] = (idx, l)
                    elif _is_plus(l):
                        plus_map[func_name] = (idx, l)
                else:
                    # Non-data rows
                    no_ansi = strip_ansi_codes(l)
                    s = no_ansi.lstrip()
                    if s[:1] in "+-":
                        s = s[1:].lstrip()
                    norm = s  # normalized content for pairing
                    length = len(no_ansi)
                    if _is_minus(l):
                        nd_minus.setdefault(norm, []).append((idx, l, length))
                    elif _is_plus(l):
                        nd_plus.setdefault(norm, []).append((idx, l, length))

            keep_map: dict[int, str] = {}  # idx -> output line
            skip_idx: set[int] = set()

            # Handle paired data rows
            for func in list(minus_map.keys() & plus_map.keys()):
                mi, ml = minus_map[func]
                pi, pl = plus_map[func]
                if compare_gas_lines(ml, pl, rel_tol, abs_tol):
                    # Exceeds tolerance: keep both
                    keep_map[mi] = ml
                    keep_map[pi] = pl
                    has_exceed = True
                else:
                    # Within tolerance: collapse to context-like from '+' line,
                    # emit at the '-' position and drop the '+'
                    collapsed = re.sub(r"^((?:\x1b\[[0-9;]*m)*)\+", r"\1 ", pl, count=1)
                    keep_map[mi] = collapsed
                    skip_idx.add(pi)
                del minus_map[func]
                del plus_map[func]

            # Remaining singletons among data rows -> structural changes
            for mi, ml in minus_map.values():
                keep_map[mi] = ml
                has_exceed = True
            for pi, pl in plus_map.values():
                keep_map[pi] = pl
                has_exceed = True

            # Handle non-data rows like context, with de-dup of equal-length +/- pairs
            for norm in set(nd_minus.keys()) | set(nd_plus.keys()):
                minus_list = nd_minus.get(norm, [])
                plus_list = nd_plus.get(norm, [])

                if minus_list and plus_list:
                    # Compare by equal length; if equal, drop '+'; else keep both
                    # Pair greedily in order of appearance
                    used_plus = set()
                    for mi, ml, mlen in minus_list:
                        # Find the earliest unused plus with equal length
                        matched_plus_idx = None
                        for k, (pi, pl, plen) in enumerate(plus_list):
                            if k in used_plus:
                                continue
                            if plen == mlen:
                                matched_plus_idx = k
                                break
                        if matched_plus_idx is not None:
                            # Keep '-' as-is, drop the matching '+'
                            keep_map[mi] = ml
                            used_plus.add(matched_plus_idx)
                            # Do not add the matched plus
                        else:
                            # No equal-length '+': keep the '-'
                            keep_map[mi] = ml
                    # Any remaining unmatched '+' keep as-is
                    for k, (pi, pl, _) in enumerate(plus_list):
                        if k not in used_plus:
                            keep_map[pi] = pl
                else:
                    # Only one side present -> keep all lines
                    for mi, ml, _ in minus_list:
                        keep_map[mi] = ml
                    for pi, pl, _ in plus_list:
                        keep_map[pi] = pl

            # Emit in original order
            for idx, l in chunk:
                if idx in skip_idx:
                    continue
                if idx in keep_map:
                    filtered_lines.append(keep_map[idx])

            i = j
            continue

        # Misc lines as-is
        filtered_lines.append(line)
        i += 1

    return filtered_lines, has_exceed


def main():

    # Parse command line arguments
    parser = argparse.ArgumentParser(description="Gas regression comparison with numerical tolerance")
    parser.add_argument(
        "--rel-tolerance",
        type=float,
        default=DEFAULT_GAS_TOLERANCE_REL,
        help=f"Relative tolerance (default: {DEFAULT_GAS_TOLERANCE_REL})",
    )
    parser.add_argument(
        "--abs-tolerance",
        type=float,
        default=DEFAULT_GAS_TOLERANCE_ABS,
        help=f"Absolute tolerance (default: {DEFAULT_GAS_TOLERANCE_ABS})",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug output",
    )

    args = parser.parse_args()

    # Set global tolerance values
    DEBUG = args.debug

    # Read git diff from stdin - preserve raw lines for debugging
    raw_lines = list(sys.stdin.readlines())
    diff_lines = [line.rstrip() for line in raw_lines]

    if DEBUG:
        print("DEBUG: Input lines (raw):")
        for i, line in enumerate(raw_lines):
            print(f"DEBUG: Raw Line {i}: {repr(line)}")

        print("\nDEBUG: Input lines (stripped):")
        for i, line in enumerate(diff_lines):
            print(f"DEBUG: Line {i}: {repr(line)}")

        print("\nDEBUG: Parsing each line:")
        for i, line in enumerate(diff_lines):
            # Try to handle leading whitespace by further trimming
            parsed = parse_gas_line(line)
            # If parsing failed, try trimming leading whitespace
            if parsed is None:
                trimmed = line.strip()
                parsed_trimmed = parse_gas_line(trimmed)
                print(f"DEBUG: Line {i}: {repr(line)} -> {parsed}, Trimmed: {repr(trimmed)} -> {parsed_trimmed}")
            else:
                print(f"DEBUG: Line {i}: {repr(line)} -> {parsed}")

    if not diff_lines:
        sys.exit(0)  # No diff, no problem

    # Filter the colored diff and detect if anything exceeded tolerance
    filtered_lines, has_exceed = filter_colored_diff_lines(diff_lines, args.rel_tolerance, args.abs_tolerance)

    if not has_exceed:
        # Nothing exceeded tolerance; still print the (collapsed) lines for visibility
        for line in filtered_lines:
            print(line)
        sys.exit(0)

    # Some differences exceeded tolerance
    for line in filtered_lines:
        print(line)
    sys.exit(1)


if __name__ == "__main__":
    main()
