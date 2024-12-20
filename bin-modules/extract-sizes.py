#!/usr/bin/env python3
import sys
import re
import pandas as pd
from tabulate import tabulate

def parse_log(input_data):
    """
    Parse the table from the input data.
    """
    # Extract the header line
    header_line = re.search(r"^\| Contract\s+\|.+\|$", input_data, re.MULTILINE).group(0)
    header = [col.strip() for col in re.split(r"\s+\|\s+", header_line.strip('| '))]

    # Extract rows containing 'src/' and clean them
    row_lines = re.findall(r"^\| [A-Za-z$_]+.+\| [0-9]+.+\|$", input_data, re.MULTILINE)

    data = []
    for row_line in row_lines:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip('| '))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header)

    return df.drop(columns=["Initcode Size (B)", "Runtime Margin (B)", "Initcode Margin (B)"])


def main():
    # Read log data from stdin
    input_data = sys.stdin.read()

    # Parse the log
    df = parse_log(input_data)

    # Format the table using tabulate
    output = tabulate(df, headers="keys", showindex=False, tablefmt="fancy_grid")

    # Write the formatted table to stdout
    sys.stdout.write(output + "\n")


if __name__ == "__main__":
    main()
