"""
Utility functions for tests.
"""
import json
import os
from pathlib import Path

def create_mock_abi(output_dir, contract_name, abi_content):
    """
    Create a mock ABI file for testing.

    Args:
        output_dir: Directory to create the ABI file in
        contract_name: Name of the contract (without .json extension)
        abi_content: Dictionary or list of ABI content

    Returns:
        Path to the created file
    """
    file_path = Path(output_dir) / f"{contract_name}.json"

    # Make sure abi_content is wrapped in the expected structure
    if isinstance(abi_content, list):
        content = {"abi": abi_content}
    else:
        content = abi_content

    with open(file_path, 'w') as f:
        json.dump(content, f, indent=2)

    return file_path

def calculate_error_selector(error_signature):
    """
    Calculate the Ethereum keccak256 selector for an error signature.

    Args:
        error_signature: Error signature string (e.g., "InvalidValue(uint256)")

    Returns:
        Error selector (first 4 bytes + 0x prefix)
    """
    import subprocess

    result = subprocess.run(
        ["cast", "keccak", error_signature],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        raise RuntimeError(f"Failed to calculate keccak hash: {result.stderr}")

    return result.stdout.strip()[:10]  # First 10 chars (0x + 8 hex chars for 4 bytes)
