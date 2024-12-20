#!/usr/bin/env python3
import sys
import re
import pandas as pd
from tabulate import tabulate
from utils import shorten

def parse_log(input_data):
    """
    Parse the table from the input data.
    """
    # Extract the header line
    header_line = re.search(r"^\| File\s+\|.+\|$", input_data, re.MULTILINE).group(0)
    header = [col.strip() for col in re.split(r"\s+\|\s+", header_line.strip('| '))]

    # Extract rows containing 'src/' and clean them
    row_lines = re.findall(r"^\| src/.+\|$", input_data, re.MULTILINE)

    data = []
    for row_line in row_lines:
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
    return df


def main():
    # Read log data from stdin
    input_data = sys.stdin.read()

    # Parse the log
    df = parse_log(input_data)

    # Shorten paths in the "File" column (adjust column name if different)
    max_path_length = 30
    # if "File" in df.columns:
        # df["File"] = df["File"].apply(lambda x: shorten(x, max_path_length))

    # Format the table using tabulate
    output = tabulate(df, headers="keys", showindex=False, tablefmt="fancy_grid")

    # Write the formatted table to stdout
    sys.stdout.write(output + "\n")


if __name__ == "__main__":
    main()
