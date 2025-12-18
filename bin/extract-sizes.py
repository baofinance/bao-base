#!/usr/bin/env python3
# pyright: reportMissingImports=false
import json
import os
import re
from pathlib import Path
from typing import cast

import forge_tables
import pandas as pd  # type: ignore[reportMissingImports]

GAS_PER_BYTE = 200
INITCODE_AVG_GAS_PER_BYTE = 10  # Half of the init bytes are assumed zero (4 gas) and half non-zero (16 gas).
USD_PER_GAS = 0.10 / 1_000  # $0.10 per 1k gas


def get_contract_source_path(contract_name: str) -> str | None:
    """Look up source path from compiled artifact metadata."""
    out_dir = Path("out")
    # Artifact is at out/**/{SourceFile}.sol/{ContractName}.json
    # The directory name is the source file (may differ from contract name),
    # but the JSON file is always named after the contract.
    pattern = f"**/*.sol/{contract_name}.json"
    matches = list(out_dir.glob(pattern))
    if not matches:
        return None
    artifact_path = matches[0]
    try:
        with open(artifact_path) as f:
            artifact = json.load(f)
        targets = artifact.get("metadata", {}).get("settings", {}).get("compilationTarget", {})
        if targets:
            return next(iter(targets.keys()))
    except (json.JSONDecodeError, KeyError, StopIteration):
        pass
    return None


def is_lib_contract(contract_name: str) -> bool:
    """Check if contract source is from lib/ directory."""
    source_path = get_contract_source_path(contract_name)
    return source_path is not None and source_path.startswith("lib/")


def toNamedDataFrame(input_data: str) -> tuple[pd.DataFrame, str]:
    """
    Parse the table from the input data.
    """
    # Extract the header line
    header_match = re.search(r"^\| Contract\s+\|.+\|$", input_data, re.MULTILINE)
    if not header_match:
        raise ValueError("Input data does not contain a valid table header.")
    header_line = header_match.group(0)
    header = [col.strip() for col in re.split(r"\s*\|\s*", header_line.strip("| "))]

    # Extract rows containing 'src/' and clean them
    rows_match = re.findall(r"^\|\s*[A-Za-z0-9$_]+\s*\|\s*[0-9]+.+\|$", input_data, re.MULTILINE)
    if not rows_match:
        raise ValueError("Input data does not contain valid table rows.")

    data: list[list[str]] = []
    for row_line in rows_match:
        # Split by '|' separator and strip whitespace from each cell
        columns = [col.strip() for col in re.split(r"\s+\|\s+", row_line.strip("| "))]
        data.append(columns)

    # Create the DataFrame using the cleaned and validated data
    df = pd.DataFrame(data, columns=header)

    # Filter out contracts from lib/ dependencies
    df = df[~df["Contract"].apply(is_lib_contract)]

    df["Runtime Size (B)"] = [int(value.replace(",", "")) for value in df["Runtime Size (B)"]]
    df["Runtime Margin (B)"] = [int(value.replace(",", "")) for value in df["Runtime Margin (B)"]]
    df["Initcode Size (B)"] = [int(value.replace(",", "")) for value in df["Initcode Size (B)"]]

    if "Initcode Margin (B)" in df.columns:
        df = df.drop(columns=["Initcode Margin (B)"])

    # columns_to_format = ["Runtime Size (B)"]
    # df[columns_to_format] = df[columns_to_format].map(lambda x: f"{x:>8}")

    deploy_gas = df["Runtime Size (B)"] * GAS_PER_BYTE + df["Initcode Size (B)"] * INITCODE_AVG_GAS_PER_BYTE
    df["Deploy Gas"] = [int(value) for value in deploy_gas]
    df["Deploy Cost ($)"] = df["Deploy Gas"] * USD_PER_GAS

    ordered_columns = [
        "Contract",
        "Runtime Size (B)",
        "Runtime Margin (B)",
        "Initcode Size (B)",
        "Deploy Gas",
        "Deploy Cost ($)",
    ]
    df = df.loc[:, ordered_columns].copy()

    return df, ""


if __name__ == "__main__":
    forge_tables.process(toNamedDataFrame, floatfmt=".2f", intfmt=",")
