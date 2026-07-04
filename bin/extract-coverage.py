#!/usr/bin/env python3
# pyright: reportGeneralTypeIssues=false
import re

import forge_tables
import pandas as pd


def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str] | None:
    """
    Parse the coverage summary table from the input data, or return None if the
    input is not the coverage table.

    process() feeds every "|...|" table in the forge log through here (compiler
    output, invariant call-summary tables, etc.), so a block that is not the
    coverage summary is skipped by returning None. Identification is by the
    coverage summary's own columns - a bare "| File |" header is not enough.
    """
    # Extract the header line - must be the coverage summary's exact columns
    header_match = re.search(
        r"^\| File\s+\| % Lines\s+\| % Statements\s+\| % Branches\s+\| % Funcs\s+\|$",
        input_data,
        re.MULTILINE,
    )
    if not header_match:
        return None
    header_line = header_match.group(0)
    header = [col.strip() for col in re.split(r"\s+\|\s+", header_line.strip("| "))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\| (?:(?:src|script)/|Total\b).+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")

    data: list[list[str]] = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip("| "))]

        # Ignore Foundry script stubs (*.s.sol) to keep focus on deployable code coverage
        if columns and columns[0].endswith(".s.sol"):
            continue

        # Ignore one-shot verification scripts (script/*/verify/)
        if columns and "/verify/" in columns[0] and columns[0].startswith("script/"):
            continue

        # Ignore duplicate paths from relative resolution (e.g. src/../script/src/)
        if columns and "/../" in columns[0]:
            continue

        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header)

    # format the data to show xxx% (nn/mm), with asterisk and padding for <100%
    def _format_coverage_cell(raw: str) -> str:
        raw = raw.strip()
        match = re.search(r"(\d+(?:\.\d+)?)%", raw)
        if not match:
            return raw

        percent_value = float(match.group(1))
        percent = f"{percent_value:2.0f}"

        if percent == "100":
            marker = "✓"
            spacer = " "
        else:
            marker = "X"
            spacer = "  "

        count_match = re.search(r"\((\d+/\d+)\)", raw)
        suffix = f" {count_match.group(0)}" if count_match else ""

        return f"{marker}{spacer}{percent}%{suffix}"

    for column in df.columns[1:5]:
        df[column] = df[column].map(_format_coverage_cell)

    # Create a pandas DataFrame
    return df, ""


if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame, floatfmt=".3e", intfmt=",")
