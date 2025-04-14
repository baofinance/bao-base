"""
ABI handling utilities for Ethereum smart contracts.

This module provides functions for retrieving and handling contract ABIs,
particularly for extracting function and event signatures.
"""

import json
import os
import sys

from mauled.core.logging import get_logger
from mauled.core.subprocess import run_command

logger = get_logger()

# ABI directory location (could be made configurable)
ABI_DIR = os.getenv("ABI_DIR", "./out")


def get_function_type_string(param):
    """
    Get the full type string for a parameter, properly formatting complex types

    Args:
        param: Parameter object from ABI

    Returns:
        str: Properly formatted type string
    """
    type_str = param.get("type", "")

    # Handle tuple types - need to recursively process components
    if type_str == "tuple":
        components = param.get("components", [])
        component_types = [get_function_type_string(comp) for comp in components]
        return f"({','.join(component_types)})"

    return type_str


def get_function_info(contract, func_name):
    """
    Get comprehensive information about a function from its ABI

    Args:
        contract: Contract name to look up
        func_name: Function name to look up

    Returns:
        dict: Dictionary containing function information:
            'signature': Full function signature (e.g. 'transfer(address,uint256)')
            'param_types': List of parameter types
            'inputs': List of input parameter details (name, type, etc.)
            'outputs': List of output parameter details
            'abi_path': Path to the contract ABI file
    """
    # Find the contract ABI file
    result = run_command(
        ["find", ABI_DIR, "-name", f"{contract}.json", "-print", "-quit"]
    )
    abi_path = result.stdout.strip()
    if not abi_path:
        print(f"error: Contract ABI file not found for {contract}")
        sys.exit(1)

    # Get detailed function information including inputs and outputs
    result = run_command(
        [
            "jq",
            f'.abi[] | select(.name == "{func_name}" and .type == "function")',
            abi_path,
        ]
    )

    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: Function {func_name} not found in contract {contract}")
        sys.exit(1)

    try:
        func_data = json.loads(result.stdout.strip())

        # Extract parameter types for the signature - properly handle complex types
        param_types = [
            get_function_type_string(input_param)
            for input_param in func_data.get("inputs", [])
        ]
        param_str = ",".join(param_types)

        return {
            "signature": f"{func_name}({param_str})",
            "param_types": param_types,
            "inputs": func_data.get("inputs", []),
            "outputs": func_data.get("outputs", []),
            "abi_path": abi_path,
        }
    except json.JSONDecodeError:
        print(f"error: Invalid JSON in ABI for {contract}.{func_name}")
        sys.exit(1)


def get_event_info(contract, event_name):
    """
    Get comprehensive information about an event from its ABI

    Args:
        contract: Contract name to look up
        event_name: Event name to look up

    Returns:
        dict: Dictionary containing event information:
            'signature': Full event signature (e.g. 'Transfer(address,address,uint256)')
            'param_types': List of parameter types
            'inputs': List of input parameter details (name, type, indexed, etc.)
            'abi_path': Path to the contract ABI file
    """
    # Find the contract ABI file
    result = run_command(
        ["find", ABI_DIR, "-name", f"{contract}.json", "-print", "-quit"]
    )
    abi_path = result.stdout.strip()
    if not abi_path:
        print(f"error: Contract ABI file not found for {contract}")
        sys.exit(1)

    # Get detailed event information including inputs
    result = run_command(
        [
            "jq",
            f'.abi[] | select(.name == "{event_name}" and .type == "event")',
            abi_path,
        ]
    )

    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: Event {event_name} not found in contract {contract}")
        sys.exit(1)

    try:
        event_data = json.loads(result.stdout.strip())

        # Extract parameter types for the signature - properly handle complex types
        param_types = [
            get_function_type_string(input_param)
            for input_param in event_data.get("inputs", [])
        ]
        param_str = ",".join(param_types)

        return {
            "signature": f"{event_name}({param_str})",
            "param_types": param_types,
            "inputs": event_data.get("inputs", []),
            "abi_path": abi_path,
        }
    except json.JSONDecodeError:
        print(f"error: Invalid JSON in ABI for {contract}.{event_name}")
        sys.exit(1)
