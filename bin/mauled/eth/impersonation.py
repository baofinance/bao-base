"""
Ethereum account impersonation utilities.

This module provides functions for impersonating Ethereum accounts in test environments.
"""

from typing import Any, Callable, Optional

from mauled.core.logging import get_logger
from mauled.eth.address import address_of

from bin.mauled.core.subprocess import run_command

logger = get_logger()


def _enable_impersonation(
    rpc_url: str, address: str, on_error: Optional[Callable] = None
) -> str:
    """
    Enable impersonation for a given address or named account.

    Args:
         rpc_url: RPC URL to use
        address: Address to impersonate
        on_error: Optional error handler function

    Returns:
        The actual impersonated address (resolved from name if needed)
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
    return address


def enable_impersonation(
    network: str, rpc_url: str, identity: str, on_error: Optional[Callable] = None
) -> str:
    """
    Enable impersonation for a given address or named account.

    Args:
        network: Network name
        rpc_url: RPC URL to use
        identity: Address or name to impersonate
        on_error: Optional error handler function

    Returns:
        The actual impersonated address (resolved from name if needed)
    """
    return _enable_impersonation(rpc_url, address_of(network, identity), on_error)


def _disable_impersonation(rpc_url: str, address: str) -> None:
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


def _with_impersonation(
    rpc_url: str,
    identity: str,
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
        identity: Address to impersonate (if None, no impersonation happens)
        callback_func: Function to execute
        on_error: Optional error handler function
        *callback_args, **callback_kwargs: Arguments to pass to the callback function

    Returns:
        Any: Result of the callback function
    """
    # Set up impersonation
    impersonation_address = _enable_impersonation(rpc_url, identity, on_error)
    try:
        # Execute the callback with the impersonation address
        return callback_func(impersonation_address, *callback_args, **callback_kwargs)
    finally:
        # Clean up impersonation
        _disable_impersonation(rpc_url, impersonation_address)


def with_impersonation(
    network: str,
    rpc_url: str,
    identity: str,
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
        identity: Address to impersonate (if None, no impersonation happens)
        callback_func: Function to execute
        on_error: Optional error handler function
        *callback_args, **callback_kwargs: Arguments to pass to the callback function

    Returns:
        Any: Result of the callback function
    """
    return _with_impersonation(
        rpc_url,
        address_of(network, identity),
        callback_func,
        *callback_args,
        on_error,
        **callback_kwargs
    )
