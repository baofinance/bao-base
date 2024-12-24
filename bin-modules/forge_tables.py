import sys
import re
import pandas as pd
from tabulate import tabulate
from typing import Callable

def extract(log_data: str) -> list[str]:
    # match patter for a table
    return re.findall(r"(?:^\|.*\|(?:\n\|.*\|)*)", log_data, re.MULTILINE)

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
