"""
Ethereum account impersonation utilities.

This module provides functions for impersonating Ethereum accounts in test environments.
"""

from typing import Any, Callable, List, Optional

from mauled.core.logging import get_logger
from mauled.core.subprocess import run_command
from mauled.eth.address_lookup import address_of

logger = get_logger()


def enable_impersonation(rpc_url: str, address: str):
    """
    Enable impersonation for a given address or named account.

    Args:
         rpc_url: RPC URL to use
        address: Address to impersonate

    """
    run_command(
        [
            "cast",
            "rpc",
            "--rpc-url",
            rpc_url,
            "anvil_impersonateAccount",
            address,
        ],
    )


def disable_impersonation(rpc_url: str, address: str) -> None:
    """
    Disable impersonation for a given address.

    Args:
        rpc_url: RPC URL to use
        address: Address to stop impersonating
    """
    run_command(
        [
            "cast",
            "rpc",
            "--rpc-url",
            rpc_url,
            "anvil_stopImpersonatingAccount",
            address,
        ],
    )


def with_impersonation(
    rpc_url: str, impersonation_address: str, callback_func: Callable, *callback_args, **callback_kwargs
) -> Any:
    """
    Execute a function with optional impersonation

    Args:
        rpc_url: RPC URL to use for the impersonation commands
        impersonation_address: Address to impersonate (if None, no impersonation happens)
        callback_func: Function to execute
        *callback_args, **callback_kwargs: Arguments to pass to the callback function

    Returns:
        Any: Result of the callback function
    """
    # If impersonation_address is provided, enable impersonation
    enable_impersonation(rpc_url, impersonation_address)
    try:
        # Execute the callback with the impersonation flags
        return callback_func(["--from", impersonation_address], *callback_args, **callback_kwargs)
    finally:
        # Clean up impersonation
        disable_impersonation(rpc_url, impersonation_address)
        raise
