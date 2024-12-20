#!/usr/bin/env python3
import sys
import re
import pandas as pd
from tabulate import tabulate

def parse_log(input_data) -> tuple[str, str, pd.DataFrame]:
    """
    Parse the table from the input data.
    """
    # Extract the header line
    file_contract = re.search(r"(\S+):(\S+)", re.split("\n", input_data)[1])
    file = file_contract.group(1)
    contract = file_contract.group(2)

    header_line = re.search(r"^\| Function Name\s+\|.+\|$", input_data, re.MULTILINE).group(0)
    header = [col.strip() for col in re.split(r"\s+\|\s+", header_line.strip('| '))]

    # Extract rows containing 'src/' and clean them
    row_lines = re.findall(r"^\| [A-Za-z$_][A-Za-z$_]+\s+\|.+\|$", input_data, re.MULTILINE)

    data = []
    for row_line in row_lines:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip('| '))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header).drop(columns=["Min", "Avg", "# Calls"])
    # columns_to_format = ["Median", "Max"]
    # df[columns_to_format] = df[columns_to_format].map(lambda x: f"{int(x):>8}")

    return (file, contract, df)


def main():
    # Read log data from stdin
    input_data = sys.stdin.read()

    # find the tables:
    tables = re.findall(r"^╭[^╭]+╯$", input_data, re.MULTILINE)

    first = True
    for table in tables:
        # Parse the log
        file, contract, df = parse_log(table)

        # Format the table using tabulate
        output = tabulate(df, headers="keys", showindex=False, tablefmt="fancy_grid")

        # Write the formatted table to stdout
        if first:
            first = False
        else:
            sys.stdout.write("\n")
        sys.stdout.write(file + " : " + contract + "\n")
        sys.stdout.write(output + "\n")


if __name__ == "__main__":
    main()
