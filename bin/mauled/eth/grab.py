"""
Ethereum balance manipulation utilities.

This module provides functions to manipulate ETH and ERC20 token balances
on Ethereum-compatible networks, particularly useful for testing.
"""

import logging
import time
from decimal import Decimal
from typing import Any, List, Literal, Optional, Union

from mauled.core.logging import get_logger
from mauled.core.subprocess import quiet_run_command, run_command
from mauled.eth.address_lookup import address_of
from mauled.eth.cast_command import (
    run_cast_balance,
    run_cast_balanceOf,
    run_cast_command,
    run_cast_latest_block,
)
from mauled.eth.conversion import from_wei, to_hex, to_wei
from mauled.eth.impersonation import with_impersonation

logger = get_logger()


def _grab(rpc_url: str, address: str, wei_amount: int):
    """
    Set ETH balance of an address to the specified wei amount

    Args:
        rpc_url: RPC URL to use
        address: Address to set balance for
        wei_amount: Amount in wei to set balance to
    """
    logger.info2(f"Setting balance of {address} to {wei_amount} wei")
    run_cast_command(
        [
            "cast",
            "rpc",
            "--rpc-url",
            rpc_url,
            "anvil_setBalance",
            address,
            to_hex(wei_amount),
        ]
    )


def grab(network: str, rpc_url: str, wallet: str, eth_amount: Decimal):
    """
    Add ETH to an address (adds to existing balance)

    Args:
        network: Network name
        rpc_url: RPC URL to use
        wallet: Wallet address or name to add ETH to
        eth_amount: Amount of ETH to add
    """
    address = address_of(network, wallet)
    wei_amount = to_wei(eth_amount)
    wei_balance = run_cast_command(["cast", "balance", "--rpc-url", rpc_url, address]).stdout.strip()

    _grab(rpc_url, address, int(wei_amount) + int(wei_balance))

    new_wei_balance = run_cast_command(["cast", "balance", "--rpc-url", rpc_url, address]).stdout.strip()
    eth_balance = run_command(["cast", "from-wei", new_wei_balance]).stdout.strip()
    logging.info(f"{wallet} balance is now {eth_balance}")


def grab_upto(network, rpc_url, wallet, eth_amount):
    """
    Set ETH balance of an address to exactly the specified amount

    Args:
        network: Network name
        rpc_url: RPC URL to use
        wallet: Wallet address or name to set ETH balance for
        eth_amount: Amount of ETH to set balance to
    """
    address = address_of(network, wallet)

    _grab(rpc_url, address, to_wei(eth_amount))

    wei_balance = run_cast_balance(address)

    logger.info(f"{wallet} balance is now {from_wei(wei_balance)}")


def _try_mint_tokens(
    rpc_url: str,
    token_address: str,
    wallet_address: str,
    wei_amount: int,
) -> bool:
    """
    Try to mint tokens directly using the token's mint function.
    """
    # First check if token has a mint function by calling its code
    code_result = run_cast_command(["cast", "code", "--rpc-url", rpc_url, token_address])

    # Quick check if the mint function signature exists in the bytecode
    # This is an optimization to avoid failing transactions
    if code_result.returncode == 0 and not "40c10f19" in code_result.stdout:
        logger.debug(f"Token {token_address} does not appear to have a mint function")
        return False

    # Try the mint function - use the original amount, not wei_amount which might be too large

    mint_result = with_impersonation(
        rpc_url,
        wallet_address,
        lambda impersonation_args: (
            run_cast_command(
                ["cast", "send", "--rpc-url", rpc_url]
                + impersonation_args
                + [
                    "mint(address,uint256)",
                    wallet_address,
                    str(wei_amount),
                ]
            ),
        ),
    )

    return mint_result.returncode == 0


def _try_whale_transfer(
    rpc_url: str,
    token_address: str,
    wallet_address: str,
    wei_amount: int,
) -> bool:
    """
    Try transferring tokens from a whale account.
    """
    # Try multiple known whales if the first one fails
    whale_addresses = [
        # Binance Hot Wallet
        "0xf977814e90da44bfa03b6295a0616a897441acec",
        # Other major holders
        "0x28c6c06298d514db089934071355e5743bf21d60",
        "0x47ac0fb4f2d84898e4d9e7b4dab3c24507a6d503",
        "0xe78388b4ce79068e89bf8aa7f218ef6b9ab0e9d0",
    ]

    for whale in whale_addresses:
        try:
            # TODO: use run_cast_command, but check for it's error handling
            # TODO: more generally, get rid of quiet_run_command and use run_command with a try except block
            # Check if the whale has enough tokens
            balance_result = run_cast_balanceOf(rpc_url, token_address, whale)

            if balance_result.returncode != 0 or not balance_result.stdout.strip():
                logger.debug(f"Whale {whale} has no tokens or balanceOf call failed")
                continue

            whale_balance = int(balance_result.stdout.strip())
            if whale_balance < wei_amount:
                logger.debug(f"Whale {whale} has insufficient balance: {whale_balance} < {wei_amount}")
                continue

            # Give the holder address some ETH to pay for gas
            _grab(rpc_url, whale, 1e18)

            transfer_result = with_impersonation(
                rpc_url,
                whale,
                lambda impersonaton_args: (
                    run_cast_command(
                        [
                            "cast",
                            "send",
                            "--rpc-url",
                            rpc_url,
                        ]
                        + impersonaton_args
                        + [
                            token_address,
                            "transfer(address,uint256)",
                            wallet_address,
                            str(wei_amount),
                        ]
                    )
                ),
            )

            if transfer_result.returncode == 0:
                logger.info(f"Successfully transferred {from_wei(wei_amount)} tokens from whale {whale}")
                return True

        except Exception as e:
            logger.debug(f"Error using whale {whale}: {str(e)}")

    # If we reach here, all whale attempts failed
    return False


def _try_direct_storage_manipulation(rpc_url: str, token_address: str, wallet_address: str, wei_amount: int) -> bool:
    """
    Try directly manipulating storage to set token balance.

    Args:
        rpc_url: RPC URL to use
        token_address: Token contract address
        wallet_address: Recipient wallet address
        wei_amount: Amount in wei to add

    Returns:
        bool: True if successful, False otherwise
    """
    try:
        # Get current balance
        current_balance = run_cast_balanceOf(rpc_url, token_address, wallet_address)

        # Use anvil_setBalance for direct manipulation
        logger.info(f"Using anvil to directly set token balance")
        new_balance = current_balance + wei_amount

        # Direct manipulation - works in test environment but not in production chains
        _grab(rpc_url, "anvil_setBalance", new_balance)

        # Verify the token balance was changed
        verify_balance = run_cast_balanceOf(rpc_url, token_address, wallet_address)

        if int(verify_balance) > current_balance:
            logger.info(f"Successfully manipulated token balance")
            return True

        return False

    except Exception as e:
        logger.debug(f"Error during direct manipulation: {str(e)}")
        return False


def _try_admin_transfer(network: str, rpc_url: str, token_address: str, wallet_address: str, wei_amount: int) -> bool:
    """
    Try impersonating admin account to transfer tokens.

    Args:
        network: Network name for impersonation
        rpc_url: RPC URL to use
        token_address: Token contract address
        wallet_address: Recipient wallet address
        wei_amount: Amount in wei to transfer

    Returns:
        bool: True if successful, False otherwise
    """
    try:
        # Get current balance for verification
        current_balance = run_cast_balanceOf(rpc_url, token_address, wallet_address)

        # Try using zero address (common admin in test environments)
        admin_address = "0x0000000000000000000000000000000000000000"

        # Impersonate the admin and try transfer
        with_impersonation(
            rpc_url,
            admin_address,
            lambda impersonation_args: (
                # First give admin some ETH to pay for gas
                _grab(rpc_url, admin_address, 1e18),
                # TODO: use with_impersonate
                # Try to execute a transfer
                run_command(
                    [
                        "cast",
                        "send",
                        "--rpc-url",
                        rpc_url,
                    ]
                    + impersonation_args
                    + [
                        token_address,
                        "transfer(address,uint256)",
                        wallet_address,
                        str(wei_amount),
                    ]
                ),
            ),
        )

        # Check if the balance increased
        final_balance = run_cast_balanceOf(
            rpc_url,
            token_address,
            wallet_address,
        )

        if int(final_balance) > current_balance:
            logger.info(f"Successfully added tokens using admin account")
            return True

        return False

    except Exception as e:
        logger.debug(f"Error using admin account: {str(e)}")
        return False


def _try_log_scanning(rpc_url: str, token_address: str, wallet_address: str, wei_amount: int) -> bool:
    """
    Try obtaining tokens by scanning logs for holders and impersonating them.

    """

    # Get the latest block for scanning backwards
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

    # Track progress
    wei_amount_transferred = 0
    done = [wallet_address.lower()]  # Use lowercase for consistent comparison

    # Start with recent blocks
    latest_block = run_cast_latest_block(rpc_url)
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
            import json

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
                balance_result = run_cast_balanceOf(rpc_url, token_address, to_address)

                if balance_result.returncode != 0 or not balance_result.stdout.strip():
                    continue

                wei_pawn_holding = int(balance_result.stdout.strip().split()[0])

                # Only process addresses with meaningful balances
                if wei_pawn_holding > 1000000:  # Small threshold to catch more token holders
                    # Calculate how much to take (90% of their balance, capped at what we still need)
                    wei_to_steal = min(wei_pawn_holding * 9 // 10, wei_amount - wei_amount_transferred)
                    eth_to_steal = run_command(["cast", "from-wei", str(wei_to_steal)]).stdout.strip()

                    logger.info(f"stealing {eth_to_steal} of {token_address} from {to_address}...")

                    # Execute the transfer with impersonation
                    with_impersonation(
                        rpc_url,
                        to_address,
                        lambda impersonation_args: (
                            # Give the address some ETH to pay for gas
                            _grab(rpc_url, to_address, 1e18),
                            # Transfer tokens
                            run_command(
                                [
                                    "cast",
                                    "send",
                                    token_address,
                                ]
                                + impersonation_args
                                + [
                                    "transfer(address,uint256)",
                                    wallet_address,
                                    str(wei_to_steal),
                                ]
                            ),
                        ),
                    )

                    # Update tracking variables
                    wei_amount_transferred += wei_to_steal
                    eth_amount_transferred = run_command(
                        ["cast", "from-wei", str(wei_amount_transferred)]
                    ).stdout.strip()
                    logger.info(f"total amount stolen so far: {eth_amount_transferred} of {wei_amount}")

                    # Exit if we have enough
                    if wei_amount_transferred >= wei_amount:
                        return

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
        remaining_eth = run_command(["cast", "from-wei", str(remaining)]).stdout.strip()
        logger.info(f"Warning: Could only find {eth_amount_transferred} of requested {wei_amount} tokens")
        logger.info(f"Missing {remaining_eth} tokens. Try checking more blocks or a different token.")
        return False
    return True


def grab_erc20(
    network: str,
    rpc_url: str,
    wallet: str,
    scaled_to_decimals_amount: Decimal,
    token: str,
    methods: List[str] = [],
) -> bool:
    """
    Get ERC20 tokens for a wallet using specified strategies or trying all available strategies.

    Strategies tried in order of specified methods:
    - whale: Transfer from whale account (large holder)
    - mint: Direct minting (if token has a mint function)
    - storage: Direct storage manipulation (anvil-only)
    - admin: Admin account transfer (impersonating zero address)
    - logs: Log scanning for token holders

    Args:
        network: Network name
        rpc_url: RPC URL to use
        wallet: Wallet address or name to add tokens to
        eth_amount: Amount of tokens to add (in ETH units)
        token: Token address or name
        methods: List of methods to try in specified order, or ["all"] to try all methods

    Returns:
        bool: True if tokens were successfully added, False otherwise
    """
    wallet_address = address_of(network, wallet)
    token_address = address_of(network, token)

    # First get the token decimals
    decimals = int(
        quiet_run_command(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc_url,
                token_address,
                "decimals()(uint8)",
            ]
        ).stdout.strip()
    )

    # Convert to wei based on decimals
    wei_amount = int(scaled_to_decimals_amount * Decimal(10**decimals))

    # Check current balance
    eth_balance = Decimal(
        run_cast_balanceOf(
            rpc_url,
            token_address,
            wallet_address,
        )
    ) / (10**decimals)
    logger.info(
        f"giving {wallet} {scaled_to_decimals_amount} (decimals:{decimals}) erc20 {token} (current: {eth_balance})..."
    )

    # Determine which methods to try
    methods_to_try = []
    if "all" in methods:
        # If "all" is specified, use all methods in a predefined optimal order
        methods_to_try = ["whale", "mint", "storage", "admin", "logs"]
    else:
        # Otherwise use the specific methods in the order specified
        methods_to_try = methods

    logger.info(f"Will try methods in this order: {', '.join(methods_to_try)}")

    # Try each method in sequence until one succeeds
    for method in methods_to_try:
        logger.info(f"Attempting method: {method}")

        if method == "whale":
            if _try_whale_transfer(network, rpc_url, token_address, wallet_address, wei_amount):
                return True

        elif method == "mint":
            if _try_mint_tokens(rpc_url, token_address, wallet_address, wei_amount):
                return True

        elif method == "storage":
            if _try_direct_storage_manipulation(rpc_url, token_address, wallet_address, wei_amount):
                return True

        elif method == "admin":
            if _try_admin_transfer(network, rpc_url, token_address, wallet_address, wei_amount):
                return True

        elif method == "logs":
            if _try_log_scanning(rpc_url, token_address, wallet_address, wei_amount):
                return True

    logger.info(f"Failed to add tokens using methods: {', '.join(methods_to_try)}")
    return False
