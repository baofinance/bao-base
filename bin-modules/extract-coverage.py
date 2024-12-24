#!/usr/bin/env python3
import re
import pandas as pd
import forge_tables

def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str]:
    """
    Parse the table from the input data.
    """
    # Extract the header line
    header_match = re.search(r"^\| File\s+\|.+\|$", input_data, re.MULTILINE).group(0)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header = [col.strip() for col in re.split(r"\s+\|\s+", header_match.strip('| '))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\| src/.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")
    
    data = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip('| '))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header)

    # format the data to show xxx% (nn/mm), with asterisk and padding for <100%
    df.iloc[:, 1:5] = df.iloc[:, 1:5].map(lambda x: (parts := x.split(' ')) and (percent := f"{float(parts[0].rstrip('%')):2.0f}") and (
        f"✓ {percent}% {parts[1]}" if percent == "100"
        else f"X  {percent}% {parts[1]}"
    ))

    # Create a pandas DataFrame
    return df, ""


if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame)