"""
Error handling utilities for Ethereum operations.

This module provides functions for handling and decoding Ethereum-specific errors,
particularly custom errors returned by smart contracts.
"""

import json
import os
import re
import sys

from mauled.core.logging import get_logger
from mauled.core.subprocess import quiet_run_command

logger = get_logger()

# ABI directory location (could be made configurable)
ABI_DIR = os.getenv("ABI_DIR", "./out")


def search_abi_for_error(abi_path, error_id, error_data):
    """
    Search an ABI file for an error definition matching the given selector

    Args:
        abi_path: Path to the ABI JSON file
        error_id: Error selector (0x + 8 hex digits)
        error_data: Full error data for parameter decoding

    Returns:
        tuple or None: (decoded_error, raw_data) if found, None otherwise
    """
    logger.debug(f"Checking ABI file: {abi_path}")

    # Extract the contract name from the path for better error messages
    contract_name = os.path.basename(abi_path).split(".")[0]

    # Extract errors using type filter
    error_result = quiet_run_command(
        ["jq", "-c", '.abi[] | select(.type == "error")', abi_path]
    )

    if error_result.returncode == 0 and error_result.stdout.strip():
        logger.debug(f"Found errors in {contract_name}")

        # Process each error definition
        for error_json in error_result.stdout.strip().split("\n"):
            try:
                error = json.loads(error_json)
                name = error.get("name", "")
                inputs = error.get("inputs", [])

                if name:
                    # Create the error signature for calldata decoding
                    param_types = [
                        input_param.get("type", "") for input_param in inputs
                    ]
                    sig = f"{name}({','.join(param_types)})"

                    # Calculate the selector to check for a match
                    selector_result = quiet_run_command(["cast", "keccak", sig])
                    if selector_result.returncode == 0:
                        # Get just the first 10 characters (0x + 8 for 4 bytes)
                        selector = selector_result.stdout.strip()[:10]
                        logger.debug(f"Error {name} has selector {selector}")

                        if selector == error_id:
                            logger.debug(
                                f"Found matching error in {contract_name}: {sig}"
                            )

                            # Try to decode the full error data with parameters
                            decoded_params = ""

                            if len(error_data) > 10 and inputs:  # Contains parameters
                                calldata_result = quiet_run_command(
                                    ["cast", "calldata", sig, error_data]
                                )
                                if (
                                    calldata_result.returncode == 0
                                    and calldata_result.stdout.strip()
                                ):
                                    # Format parameter names if available
                                    param_info = []
                                    decoded_values = (
                                        calldata_result.stdout.strip().split("\n")
                                    )

                                    for i, param in enumerate(inputs):
                                        if i < len(decoded_values):
                                            param_name = param.get("name", f"param{i}")
                                            param_value = decoded_values[i].strip()
                                            param_info.append(
                                                f"{param_name}={param_value}"
                                            )

                                    decoded_params = ", ".join(param_info)

                            # Build full error description
                            error_description = f"Error: {name}"
                            if decoded_params:
                                error_description += f"({decoded_params})"

                            # Include the contract name for context
                            error_description += f" [from {contract_name}]"

                            # Return both the decoded error and the raw data
                            return error_description, error_data
            except Exception as e:
                logger.debug(f"Error processing error definition: {e}")

    return None


def decode_custom_error(error_data, contract_name=None, sig_input=None):
    """
    Attempt to decode a custom error returned by a contract

    Args:
        error_data: The error data string (e.g. '0xc6052bd8')
        contract_name: Optional contract name to look for the error in
        sig_input: The signature input that was used (for contract name extraction)

    Returns:
        tuple: (decoded_error, raw_data)
            decoded_error - Human-readable error message
            raw_data - Original error data
    """
    if not error_data.startswith("0x"):
        return f"Error: {error_data}", error_data

    error_id = error_data[:10]  # Error selector is first 4 bytes (8 hex chars + '0x')
    logger.debug(f"Looking up error selector: {error_id}")

    # Extract contract name from the signature input if available
    if sig_input and "." in sig_input and not contract_name:
        contract_name = sig_input.split(".", 1)[0]
        logger.debug(f"Extracted contract name {contract_name} from signature")

    # Try to get error signature using cast 4byte-decode first
    logger.debug(f"Trying to decode error selector {error_id}")
    result = quiet_run_command(["cast", "4byte-decode", error_id])
    if result.returncode == 0 and result.stdout.strip():
        logger.debug(f"Found error via 4byte-decode: {result.stdout.strip()}")
        return f"Error: {result.stdout.strip()}", error_data

    # Look for error definitions in contract ABIs
    contract_names = []

    # First, try the specifically mentioned contract
    if contract_name:
        contract_names.append(contract_name)

    # If we have a target contract address, find all ABIs and check them
    if len(error_id) == 10:  # Valid selector
        # First search in the specific contract's ABI
        if contract_name:
            # Find the contract ABI file
            find_result = quiet_run_command(
                ["find", ABI_DIR, "-name", f"{contract_name}.json", "-print", "-quit"]
            )

            if find_result.returncode == 0 and find_result.stdout.strip():
                found_error = search_abi_for_error(
                    find_result.stdout.strip(), error_id, error_data
                )
                if found_error:
                    return found_error

        # Then search all contract ABIs
        logger.debug("Searching all contract ABIs for the error selector")
        find_all_result = quiet_run_command(
            ["find", ABI_DIR, "-name", "*.json", "-type", "f"]
        )

        if find_all_result.returncode == 0 and find_all_result.stdout.strip():
            for abi_path in find_all_result.stdout.strip().split("\n"):
                # Skip already checked contract
                if contract_name and abi_path.endswith(f"/{contract_name}.json"):
                    continue

                found_error = search_abi_for_error(abi_path, error_id, error_data)
                if found_error:
                    return found_error

    # If all attempts fail, return the original error data
    return f"Custom error: {error_id}", error_data


def ethereum_error_handler(result):
    """
    Custom error handler for Ethereum commands that can decode custom errors.

    This handler attempts to decode custom error data returned by Ethereum contracts.

    Args:
        result: Command execution result containing stdout, stderr, and args
    """
    print(f"*** Command failed: {' '.join(result.args)}")

    # Extract command info for better error context
    cmd_type = result.args[0] if result.args else "Unknown"
    sig_input = None
    if (
        len(result.args) > 3
        and cmd_type in ["cast"]
        and result.args[1] in ["call", "send"]
    ):
        # For call/send, the signature is the 3rd arg
        sig_input = result.args[3] if len(result.args) > 3 else None

    if result.stderr:
        error_msg = result.stderr.strip()

        # Look for custom error pattern in the error message
        custom_error_match = None
        if "custom error" in error_msg:
            # Extract the custom error data
            custom_error_match = re.search(
                r'custom error ([^,\s]+)(?:, data: "([^"]+)")?', error_msg
            )

        if custom_error_match:
            error_selector = custom_error_match.group(1)
            error_data = (
                custom_error_match.group(2)
                if custom_error_match.group(2)
                else error_selector
            )

            # Try to decode the error with context from the command
            decoded_error, raw_data = decode_custom_error(
                error_data, sig_input=sig_input
            )

            # Print both decoded error and raw data
            print(f"*** {decoded_error}")
            print(f"*** Raw error data: {raw_data}")
        else:
            print(f"*** Error: {error_msg}")

    if result.stdout:
        print(f"*** Output: {result.stdout.strip()}")

    print(f"*** Exit code: {result.returncode}")
    sys.exit(result.returncode)
