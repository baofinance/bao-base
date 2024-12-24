#!/usr/bin/env python3
import re
import pandas as pd
import forge_tables

def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str]:
    """
    Parse the table from the input data.
    """
    # Extract the header line
    header_match = re.search(r"^\| Contract\s+\|.+\|$", input_data, re.MULTILINE).group(0)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header = [col.strip() for col in re.split(r"\s*\|\s*", header_match.strip('| '))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\|\s*[A-Za-z0-9$_]+\s*\|\s*[0-9]+.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")

    data = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip('| '))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header).drop(columns=["Initcode Size (B)", "Runtime Margin (B)", "Initcode Margin (B)"])

    # columns_to_format = ["Runtime Size (B)"]
    # df[columns_to_format] = df[columns_to_format].map(lambda x: f"{x:>8}")

    return df, ""

if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame)
