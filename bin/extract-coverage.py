#!/usr/bin/env python3
# pyright: reportGeneralTypeIssues=false
import re

import forge_tables
import pandas as pd


def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str]:
    """
    Parse the table from the input data.
    """
    # Extract the header line
    header_match = re.search(r"^\| File\s+\|.+\|$", input_data, re.MULTILINE)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header_line = header_match.group(0)
    header = [col.strip() for col in re.split(r"\s+\|\s+", header_line.strip("| "))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\| src/.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")

    data: list[list[str]] = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip("| "))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header)

    # format the data to show xxx% (nn/mm), with asterisk and padding for <100%
    def _format_coverage_cell(raw: str) -> str:
        parts = raw.split(" ")
        percent_value = float(parts[0].rstrip("%"))
        percent = f"{percent_value:2.0f}"
        if percent == "100":
            marker = "✓"
            spacer = " "
        else:
            marker = "X"
            spacer = "  "
        return f"{marker}{spacer}{percent}% {parts[1]}"

    for column in df.columns[1:5]:
        df[column] = df[column].map(_format_coverage_cell)

    # Create a pandas DataFrame
    return df, ""


if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame, floatfmt=".3e", intfmt=",")
