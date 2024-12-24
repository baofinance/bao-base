import sys
import re
import pandas as pd
from tabulate import tabulate
from typing import Callable

def extract(log_data: str) -> list[str]:
    # extract a block of text that matches a table
    result = []
    in_group = False
    for line in log_data.splitlines():
        if re.match(r'^[|+][ -+|=]+[|+]$', line):  # Ignore lines
            #print(f"reject={line}")
            continue
        elif re.match(r'^[|].+[|]$', line):  # Match valid |...| lines
            if not in_group:  # start a new group
                #print(f"new   ={line}")
                result.append(line)
                in_group = True
            else:  # append to existing group
                #print(f"append={line}")
                result[-1] += f"\n{line}"
        else: # break the group
            #print(f"break ={line}")
            in_group = False

    return result

def toStr(df: pd.DataFrame) -> str:
    # how we want to store the dataframe
    return tabulate(df, headers="keys", showindex=False, tablefmt="fancy_grid")

def process(toNamedDataFrame: Callable[[str], tuple[pd.DataFrame, str]]):
    first = True
    for table in extract(sys.stdin.read()):
        # Parse the table
        df, path = toNamedDataFrame(table)

        # Write the formatted table to stdout
        if first:
            first = False
        else:
            sys.stdout.write("\n")

        if (path):
            sys.stdout.write(path + "\n")
        sys.stdout.write(toStr(df) + "\n")
