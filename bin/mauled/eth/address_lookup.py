"""
Ethereum address resolution utilities.

This module provides functions for resolving names to addresses and getting
information about contracts from configuration.
"""

import json
import os
import sys
from typing import List

import commentjson
from mauled.core.logging import get_logger

from bin.mauled.core.subprocess import run_command

logger = get_logger()

deploy_log = "./log/deploy-local.log"  # Moved from maul.py


def bcinfo(network, name, field="address"):
    """
    Get information about a contract or address from bcinfo JSON files.
    Direct Python implementation with support for JSON with comments.

    Args:
        network: Network to look up info for (e.g., 'mainnet', 'arbitrum')
        name: Contract/address name to look up
        field: Field to extract (defaults to 'address')

    Returns:
        String with the requested information or empty string if not found
    """
    # Path to the bcinfo JSON file for the given network
    bcinfo_file = os.path.join(
        os.getenv("BAO_BASE_SCRIPT_DIR", ""), f"bcinfo.{network}.json"
    )

    try:
        # Check if file exists
        if not os.path.isfile(bcinfo_file):
            logger.debug(f"bcinfo file not found: {bcinfo_file}")
            return ""

        # Read and parse the file with commentjson to handle comments
        with open(bcinfo_file, "r") as f:
            data = commentjson.load(f)

        # Extract the requested field
        if name in data and field in data[name]:
            return str(data[name][field])

        logger.debug(f"Key {name}.{field} not found in bcinfo for {network}")
        return ""

    except Exception as e:
        logger.debug(f"Error in bcinfo: {str(e)}")
        return ""


def address_of(network, wallet):
    """
    Resolve a name or identifier to an Ethereum address.

    Args:
        network: Network to look up addresses for
        wallet: Address, name, or special identifier to resolve

    Returns:
        str: Ethereum address as a hex string
    """
    if wallet is None:
        return None

    if wallet.startswith("0x"):
        return wallet
    elif wallet.lower() == "me":
        pk = os.getenv("PRIVATE_KEY")
        if pk:
            # Wallet address conversion shouldn't fail
            result = run_command(["cast", "wallet", "address", "--private-key", pk])
            return result.stdout.strip()
        else:
            print("error: no private key found in env")
            sys.exit(1)
    else:
        address = bcinfo(network, wallet)
        if not address and os.path.isfile(deploy_log):
            with open(deploy_log) as f:
                data = json.load(f)
                address = data.get("addresses", {}).get(wallet, "")
        if not address:
            address = wallet
        return address


def address_of_arguments(
    network: str, args_list: List[str], param_types: List[str]
) -> List[str]:
    """
    Process arguments for a function call or transaction.
    Resolves addresses when parameter type is 'address'.

    Args:
        network: Network name
        args_list: List of arguments
        param_types: List of parameter types

    Returns:
        Processed list of arguments
    """
    processed_args = []
    for i, arg in enumerate(args_list):
        # Check if this parameter is an address type
        is_address = i < len(param_types) and "address" in param_types[i]

        if is_address:
            # Convert the argument to an address
            processed_args.append(address_of(network, arg))
        else:
            processed_args.append(arg)

    if processed_args != args_list:
        logger.debug(f"Converted arguments: {args_list} -> {processed_args}")

    return processed_args
