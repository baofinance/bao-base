#!/usr/bin/env python3
import forge_tables
import re
import pandas as pd

def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str]:
    """
    Parse the table from the input data.
    """
    # Extract the header line
    path_match = re.search(r"(\S+)\s*:\s*(\S+)", input_data)
    if not path_match:
        raise ValueError("Input data does not contain the expected 'file:contract' pattern.")
    
    file = path_match.group(1)
    contract = path_match.group(2)

    header_match = re.search(r"^\| Function Name\s+\|.+\|$", input_data, re.MULTILINE).group(0)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header = [col.strip().lower() for col in re.split(r"\s+\|\s+", header_match.strip('| '))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\| [A-Za-z$_][A-Za-z$_]+\s+\|.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")
    
    data = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip('| '))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header).drop(columns=["min", "avg", "# calls"])
    # columns_to_format = ["median", "max"]
    # df[columns_to_format] = df[columns_to_format].map(lambda x: f"{int(x):>8}")

    return (df, file + ":" + contract)

if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame)
