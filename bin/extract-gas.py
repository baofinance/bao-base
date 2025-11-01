#!/usr/bin/env python3
import re

import forge_tables
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

    header_match = re.search(r"^\| Function Name\s+\|.+\|$", input_data, re.MULTILINE)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header_line = header_match.group(0)
    header = [col.strip().lower() for col in re.split(r"\s+\|\s+", header_line.strip("| "))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\| [A-Za-z$_][A-Za-z$_]+\s+\|.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")

    data: list[list[str]] = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip("| "))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header).drop(columns=["min", "avg", "median", "# calls"])
    # columns_to_format = ["median", "max"]
    # df[columns_to_format] = df[columns_to_format].map(lambda x: f"{int(x):>8}")
    # Format the 'max' column to the nearest 1000
    # if "max" in df.columns:
    df["max"] = df["max"].astype(float)
    # df["max"] = df["max"].apply(lambda x: f"0{float(x):.2e}".replace("e+0", "e"))
    # df["max"] = df["max"].astype(str)
    # df["max"] = df["max"].apply(lambda x: f"{round(x/1000):,} k")
    # df["max"] = df["max"].apply(lambda x: f"{x:.2e}")  # e.g., 1.23e+05
    # df["max"] = df["max"].apply(lambda x: f"{float(x):.2e}")
    # df["max"] = df["max"].apply(lambda x: np.format_float_scientific(x, precision=2, exp_digits=2))
    # df["max"] = df["max"].apply(lambda x: f"{x:e}")

    # pd.set_option("display.float_format", "{:,}".format)
    return (df, file + ":" + contract)


if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame, floatfmt=".3e", intfmt=",")
