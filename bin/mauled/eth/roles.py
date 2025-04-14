"""
Ethereum role management utilities.

This module provides functions for resolving and managing roles on Ethereum contracts.
"""

from mauled.core.subprocess import run_command

from bin.mauled.eth.address_lookup import address_of


def role_number_of(network, rpc_url, role, on):
    """
    Get the numerical value for a role name on a contract.

    Args:
        network: Network name
        rpc_url: RPC URL to use
        role: Role name or ID to look up
        on: Contract address or name with the role

    Returns:
        str: Role number as a string

    Raises:
        ValueError: If the role is not found on the contract
    """
    if role.startswith("0x") or role.isdigit():
        return role
    on_address = address_of(network, on)
    result = run_command(
        ["cast", "call", "--rpc-url", rpc_url, on_address, f"{role}()(uint256)"]
    )
    output = result.stdout.strip().split()
    if not output:
        raise ValueError(f"Role {role} not found on {on}")
    return output[0]
