"""Ethereum token operations for maul."""

import contextlib
import json
import os

from bin.maul.logging import get_logger
from bin.maul.utils import (address_of, ether_to_wei, quiet_run_command,
                            run_command, wei_to_ether, wei_to_hex)

logger = get_logger()


def grab(network, wallet, eth_amount, rpc_url="http://localhost:8545"):
    """
    Add ETH to a wallet by using anvil_setBalance.
    Handles address resolution and ether/wei conversion.

    Args:
        network: Network to use
        wallet: Address or name to receive ETH
        eth_amount: Amount of ETH to add (as string in ether)
        rpc_url: RPC URL for the Ethereum node (default: http://localhost:8545)

    Returns:
        str: New balance in ETH as a string
    """
    # Ensure RPC URL is provided
    if not rpc_url:
        raise ValueError("RPC URL must be provided to grab function")

    # Resolve the address
    wallet_address = address_of(network, wallet)

    # Convert the amount to wei
    wei_amount = ether_to_wei(eth_amount)

    # Convert to hex for the RPC call
    hex_amount = wei_to_hex(wei_amount)

    # Set the balance using anvil_setBalance
    cmd = ["cast", "rpc", "--rpc-url", rpc_url, "anvil_setBalance", wallet_address, hex_amount]
    logger.info(f">>> {' '.join(cmd)}")
    run_command(cmd)

    # For "balance" subcommand, --rpc-url comes BEFORE the subcommand
    balance_cmd = ["cast", "--rpc-url", rpc_url, "balance", wallet_address]
    logger.info(f">>> {' '.join(balance_cmd)}")
    balance_result = run_command(balance_cmd)

    # Format balance to be human-readable
    wei_balance = balance_result.stdout.strip()
    readable_balance = wei_to_ether(wei_balance)

    logger.info(f"{wallet} balance is now {readable_balance}")

    return readable_balance


def grab_erc20(network, wallet, eth_amount, token, rpc_url="http://localhost:8545"):
    """
    Get ERC20 tokens for a wallet by impersonating holders from the event logs.

    Args:
        network: Network name
        wallet: Wallet name or address
        eth_amount: Amount of tokens to get (in ETH units)
        token: Token name or address
        rpc_url: RPC URL to use (default: http://localhost:8545)

    Returns:
        dict: Result information with amounts transferred
    """
    wallet_address = address_of(network, wallet)
    token_address = address_of(network, token)

    # Check current balance
    wei_balance = (
        run_command(
            [
                "cast",
                "call",
                token_address,
                "balanceOf(address)(uint256)",
                wallet_address,
            ]
        )
        .stdout.strip()
        .split()[0]
    )
    eth_balance = wei_to_ether(wei_balance)
    logger.info(f"Giving {wallet} {eth_amount} erc20 {token} (current: {eth_balance})...")

    # Convert to wei
    wei_amount = int(ether_to_wei(eth_amount))

    # Track progress
    wei_amount_transferred = 0
    eth_amount_transferred = "0.0"  # Initialize to avoid UnboundLocalError
    done = [wallet_address.lower()]  # Use lowercase for consistent comparison

    # Start with recent blocks
    latest_block = int(run_command(["cast", "block", "latest", "-f", "number"]).stdout.strip())
    block_window = 2000
    blocks_to_check = [(latest_block - block_window, latest_block)]

    # Process blocks until we have enough tokens or run out of blocks
    while blocks_to_check and wei_amount_transferred < wei_amount:
        start_block, end_block = blocks_to_check.pop(0)
        if start_block < 0:
            start_block = 0

        # Get Transfer events using JSON output for easier parsing
        logger.debug(f"Checking blocks {start_block} to {end_block}")
        events = quiet_run_command(
            [
                "cast",
                "logs",
                "--from-block",
                str(start_block),
                "--to-block",
                str(end_block),
                "--address",
                token_address,
                "Transfer(address,address,uint256)",
                "--json",  # Request JSON output format
            ]
        )

        # Skip if error or no events
        if events.returncode != 0 or not events.stdout.strip():
            # Queue earlier blocks to check
            if start_block > 0:
                new_end = start_block - 1
                new_start = max(0, new_end - block_window)
                blocks_to_check.append((new_start, new_end))
            continue

        # Parse JSON events
        try:
            logs = json.loads(events.stdout)
            logger.debug(f"Found {len(logs)} Transfer events")

            # Process each event
            recipients = []
            for log in logs:
                # Standard ERC20 Transfer event has:
                # topics[0]: Event signature
                # topics[1]: From address (indexed)
                # topics[2]: To address (indexed)
                # data: Amount (not indexed)
                topics = log.get("topics", [])
                if len(topics) >= 3:
                    # Extract 'to' address from topics[2]
                    # Topic values are 32 bytes (64 hex chars + 0x), but addresses are 20 bytes (40 hex chars)
                    padded_to_address = topics[2]
                    # Take the last 40 characters (20 bytes) to get the address
                    to_address = "0x" + padded_to_address[-40:]
                    recipients.append(to_address.lower())
        except json.JSONDecodeError:
            logger.debug("Failed to parse JSON output from cast logs")
            # If we can't parse the JSON, just skip this block range and try another
            if start_block > 0:
                new_end = start_block - 1
                new_start = max(0, new_end - block_window)
                blocks_to_check.append((new_start, new_end))
            continue

        logger.debug(f"Found {len(recipients)} potential token holders")

        # Process each unique recipient
        for to_address in set(recipients):
            # Skip already processed or zero address
            if to_address in done or to_address == "0x0000000000000000000000000000000000000000":
                continue

            done.append(to_address)
            logger.debug(f"Checking balance of: {to_address}")

            try:
                # Get token balance of this address
                balance_result = quiet_run_command(
                    [
                        "cast",
                        "call",
                        token_address,
                        "balanceOf(address)(uint256)",
                        to_address,
                    ]
                )

                if balance_result.returncode != 0 or not balance_result.stdout.strip():
                    continue

                wei_pawn_holding = int(balance_result.stdout.strip().split()[0])

                # Only process addresses with meaningful balances
                if wei_pawn_holding > 1000000:  # Small threshold to catch more token holders
                    # Calculate how much to take (90% of their balance, capped at what we still need)
                    wei_to_steal = min(
                        wei_pawn_holding * 9 // 10, wei_amount - wei_amount_transferred
                    )
                    eth_to_steal = wei_to_ether(str(wei_to_steal))

                    logger.info(f"Stealing {eth_to_steal} of {token} from {to_address}...")

                    # Use the with_impersonation helper
                    with with_impersonation(
                        network, to_address, rpc_url=rpc_url
                    ) as impersonated_address:
                        # Give the address some ETH to pay for gas
                        run_command(
                            [
                                "cast",
                                "rpc",
                                "--rpc-url",
                                rpc_url,
                                "anvil_setBalance",
                                to_address,
                                wei_to_hex("27542757796200000000"),
                            ]
                        )

                        # Transfer tokens
                        run_command(
                            [
                                "cast",
                                "send",
                                "--rpc-url",
                                rpc_url,
                                token_address,
                                "transfer(address,uint256)",
                                wallet_address,
                                str(wei_to_steal),
                                "--from",
                                impersonated_address,
                                "--unlocked",
                            ]
                        )

                    # Update tracking variables
                    wei_amount_transferred += wei_to_steal
                    eth_amount_transferred = wei_to_ether(str(wei_amount_transferred))
                    logger.info(
                        f"Total amount stolen so far: {eth_amount_transferred} of {eth_amount}"
                    )

                    # Exit if we have enough
                    if wei_amount_transferred >= wei_amount:
                        return {
                            "status": "success",
                            "requested": eth_amount,
                            "acquired": eth_amount_transferred,
                            "token": token,
                        }

            except Exception as e:
                logger.debug(f"Error processing address {to_address}: {str(e)}")

        # Queue up earlier blocks to check if we need more tokens
        if wei_amount_transferred < wei_amount and start_block > 0:
            new_end = start_block - 1
            new_start = max(0, new_end - block_window)
            blocks_to_check.append((new_start, new_end))

    # If we still couldn't find enough tokens
    if wei_amount_transferred < wei_amount:
        remaining = wei_amount - wei_amount_transferred
        remaining_eth = wei_to_ether(str(remaining))
        logger.warning(f"Could only find {eth_amount_transferred} of requested {eth_amount} tokens")
        logger.warning(
            f"Missing {remaining_eth} tokens. Try checking more blocks or a different token."
        )

    return {
        "status": "partial" if wei_amount_transferred < wei_amount else "success",
        "requested": eth_amount,
        "acquired": eth_amount_transferred,
        "token": token,
    }


@contextlib.contextmanager
def with_impersonation(network, identity, rpc_url):
    """
    Context manager for impersonating an address.

    This is the canonical implementation that other functions should use.

    Args:
        network: Network name
        identity: Address or name to impersonate
        rpc_url: RPC URL for the Ethereum node

    Yields:
        str: The resolved impersonation address or None if identity is None
    """
    if not identity:
        # Nothing to impersonate, just yield None
        yield None
        return

    # Resolve the address
    impersonation_address = address_of(network, identity)
    if not impersonation_address:
        logger.error(f"Failed to resolve impersonation address for {identity}")
        raise ValueError(f"Cannot impersonate invalid address: {identity}")

    logger.debug(f"Impersonating {impersonation_address} on {network}")

    rpc_args = ["--rpc-url", rpc_url]

    # Set up impersonation
    try:
        run_command(
            ["cast", "rpc"] + rpc_args + ["anvil_impersonateAccount", impersonation_address]
        )
        # Add ETH to the impersonated account to ensure it can pay for gas
        run_command(
            ["cast", "rpc"]
            + rpc_args
            + ["anvil_setBalance", impersonation_address, "0x56BC75E2D63100000"]  # 100 ETH in hex
        )

        # Yield the impersonation address so the caller can use it
        yield impersonation_address
    finally:
        try:
            # Clean up impersonation
            run_command(
                ["cast", "rpc"]
                + rpc_args
                + ["anvil_stopImpersonatingAccount", impersonation_address]
            )
        except Exception as e:
            logger.warning(f"Failed to stop impersonating {impersonation_address}: {e}")


def impersonate(network, identity, callback_func, *callback_args, rpc_url=None, **callback_kwargs):
    """
    Execute a function with impersonation.

    This is a function-based wrapper around the with_impersonation context manager.

    Args:
        network: Network name
        identity: Address or name to impersonate (if None, no impersonation happens)
        callback_func: Function to execute
        *callback_args: Arguments to pass to the callback function
        rpc_url: RPC URL to use (defaults to http://localhost:8545)
        **callback_kwargs: Keyword arguments to pass to the callback function

    Returns:
        Result from the callback function
    """
    # Use default RPC URL if not provided
    rpc_url = rpc_url or "http://localhost:8545"

    # Ensure the rpc_url is included in callback_kwargs
    if "rpc_url" not in callback_kwargs:
        callback_kwargs["rpc_url"] = rpc_url

    # Use the context manager implementation
    with with_impersonation(network, identity, rpc_url=rpc_url) as impersonation_address:
        return callback_func(impersonation_address, *callback_args, **callback_kwargs)
