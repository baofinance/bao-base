"""
Ethereum account impersonation utilities.

This module provides functions for impersonating Ethereum accounts in test environments.
"""

from typing import Any, Callable, List, Optional

from mauled.core.logging import get_logger

from bin.mauled.core.subprocess import run_command
from bin.mauled.eth.address_lookup import address_of

logger = get_logger()


def enable_impersonation(
    rpc_url: str, address: str, on_error: Optional[Callable] = None
):
    """
    Enable impersonation for a given address or named account.

    Args:
         rpc_url: RPC URL to use
        address: Address to impersonate
        on_error: Optional error handler function

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
        on_error=on_error,
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
        # Don't exit on cleanup errors, just log them
        exit_on_error=False,
    )


def with_impersonation(
    rpc_url: str,
    impersonation_address: str,
    default_signer: str,
    callback_func: Callable,
    *callback_args,
    on_error: Optional[Callable] = None,
    **callback_kwargs
) -> Any:
    """
    Execute a function with optional impersonation

    Args:
        network: Network name
        rpc_url: RPC URL to use for the impersonation commands
        impersonation_address: Address to impersonate (if None, no impersonation happens)
        default_signer: the address, if no impersonation_address is given to take on signing
        callback_func: Function to execute
        on_error: Optional error handler function
        *callback_args, **callback_kwargs: Arguments to pass to the callback function

    Returns:
        Any: Result of the callback function
    """
    if impersonation_address:
        # If impersonation_address is provided, enable impersonation
        enable_impersonation(rpc_url, impersonation_address, on_error)
        try:
            # Execute the callback with the impersonation flags
            return callback_func(
                ["--from", impersonation_address], *callback_args, **callback_kwargs
            )
        finally:
            # Clean up impersonation
            disable_impersonation(rpc_url, impersonation_address)

    else:
        # If no impersonation_address is provided, just execute the callback with empty flags
        return callback_func(
            ["--from", default_signer, "--unlocked"], *callback_args, **callback_kwargs
        )
