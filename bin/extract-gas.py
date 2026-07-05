#!/usr/bin/env python3
import re

import forge_tables
import pandas as pd

# Paths to include in gas regression (prefix match)
INCLUDE_PATHS = [
    "src/",
    "script/",
    "test/mocks/",
]

# Suffixes to exclude (applied after include filter)
EXCLUDE_SUFFIXES = [
    ".s.sol",  # script files
    ".t.sol",  # test files
]


def should_include(file_path: str) -> bool:
    """Check if a file path should be included in the gas report."""
    # First check if it matches an include path
    if not any(file_path.startswith(prefix) for prefix in INCLUDE_PATHS):
        return False
    # Then check it doesn't match any exclude suffix
    if any(file_path.endswith(suffix) for suffix in EXCLUDE_SUFFIXES):
        return False
    return True


def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str] | None:
    """
    Parse the table from the input data.
    Returns None if the file path should be filtered out.
    """
    # A gas report table is identified by its contract header line:
    #   | <file>:<contract> Contract | ...
    # forge interleaves other bordered tables in the same stream (e.g. the
    # invariant-test call summary "| Contract | Selector | Calls | ... |"), which
    # carry no file:contract header - those are not gas tables, so skip them.
    path_match = re.search(r"^\|\s*(\S+):(\S+)\s+Contract\b", input_data, re.MULTILINE)
    if not path_match:
        return None

    file = path_match.group(1)
    contract = path_match.group(2)

    # Filter out paths not in INCLUDE_PATHS
    if not should_include(file):
        return None

    header_match = re.search(r"^\| Function Name\s+\|.+\|$", input_data, re.MULTILINE)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header_line = header_match.group(0)
    header = [col.strip().lower() for col in re.split(r"\s+\|\s+", header_line.strip("| "))]

    # Extract rows containing 'src/' and clean them
    # Function names may include full signatures for overloads: e.g. mintPeggedToken(uint256,address,uint256)
    # Exclude header row ("Function Name") by requiring no space before any '(' or end of name
    rows_match = re.findall(r"^\| [A-Za-z$_][A-Za-z0-9$_]*(?:\([A-Za-z0-9,_ ]*\))?\s+\|.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")

    data: list[list[str]] = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip("| "))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header).drop(columns=["min", "avg", "median", "# calls"])
    # Emit the exact integer max; the merge (compare-gas.py) does tolerance/ratchet and renders the
    # friendly display column, so the extract must stay precise (an abs tolerance needs the real value).
    df["max"] = df["max"].astype(float).round().astype("int64")
    return (df, file + ":" + contract)


if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame, floatfmt=".3e", intfmt="")
