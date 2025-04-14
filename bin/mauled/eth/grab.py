"""
Ethereum balance manipulation utilities.

This module provides functions to manipulate ETH and ERC20 token balances
on Ethereum-compatible networks, particularly useful for testing.
"""

import logging
import time
from typing import Any, Literal, Optional, Union

from mauled.core.logging import get_logger
from mauled.eth.address import address_of
from mauled.eth.impersonation import with_impersonation

from bin.mauled.core.subprocess import run_command, run_command_quiet

logger = get_logger()

# Define the available methods for ERC20 token acquisition
TokenAcquisitionMethod = Literal["mint", "whale", "storage", "admin", "logs", "all"]


def _grab(rpc_url, address, wei_amount):
    """
    Set ETH balance of an address to the specified wei amount

    Args:
        rpc_url: RPC URL to use
        address: Address to set balance for
        wei_amount: Amount in wei to set balance to
    """
    logger.info2(f"Setting balance of {address} to {wei_amount} wei")
    # cast to hex to avoid issues with large numbers
    wei_amount_hex = run_command(["cast", "to-hex", str(wei_amount)]).stdout.strip()

    run_command(
        [
            "cast",
            "rpc",
            "--rpc-url",
            rpc_url,
            "anvil_setBalance",
            address,
            wei_amount_hex,
        ]
    )


def grab(network, rpc_url, wallet, eth_amount):
    """
    Add ETH to an address (adds to existing balance)

    Args:
        network: Network name
        rpc_url: RPC URL to use
        wallet: Wallet address or name to add ETH to
        eth_amount: Amount of ETH to add
    """
    address = address_of(network, wallet)
    wei_amount = run_command(["cast", "to-wei", eth_amount]).stdout.strip()
    wei_balance = run_command(
        ["cast", "balance", "--rpc-url", rpc_url, address]
    ).stdout.strip()

    _grab(rpc_url, address, int(wei_amount) + int(wei_balance))

    new_wei_balance = run_command(
        ["cast", "balance", "--rpc-url", rpc_url, address]
    ).stdout.strip()
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
    wei_amount = run_command(["cast", "to-wei", eth_amount]).stdout.strip()

    _grab(rpc_url, address, wei_amount)

    wei_balance = run_command(["cast", "balance", address]).stdout.strip()
    eth_balance = run_command(["cast", "from-wei", wei_balance]).stdout.strip()
    print(f"*** {wallet} balance is now {eth_balance}")


def _try_mint_tokens(
    rpc_url: str,
    token_address: str,
    wallet_address: str,
    wei_amount: int,
    eth_amount: str,
) -> bool:
    """
    Try to mint tokens directly using the token's mint function.

    Args:
        rpc_url: RPC URL to use
        token_address: Token contract address
        wallet_address: Recipient wallet address
        wei_amount: Amount in wei to mint
        eth_amount: Human-readable amount for logging

    Returns:
        bool: True if successful, False otherwise
    """
    print(f"*** Trying mint strategy...")

    mint_result = run_command_quiet(
        [
            "cast",
            "send",
            "--rpc-url",
            rpc_url,
            token_address,
            "mint(address,uint256)",
            wallet_address,
            str(wei_amount),
            "--unlocked",
        ]
    )

    if mint_result.returncode == 0:
        print(f"*** Successfully minted {eth_amount} tokens directly")
        return True

    return False


def _try_whale_transfer(
    network: str,
    rpc_url: str,
    token_address: str,
    wallet_address: str,
    wei_amount: int,
    eth_amount: str,
) -> bool:
    """
    Try transferring tokens from a whale account.

    Args:
        network: Network name for impersonation
        rpc_url: RPC URL to use
        token_address: Token contract address
        wallet_address: Recipient wallet address
        wei_amount: Amount in wei to transfer
        eth_amount: Human-readable amount for logging

    Returns:
        bool: True if successful, False otherwise
    """
    print(f"*** Trying whale transfer strategy...")

    try:
        # Find the largest token holder - using a known whale address
        top_holder = "0xf977814e90da44bfa03b6295a0616a897441acec"  # Binance Hot Wallet

        top_holder_result = run_command_quiet(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc_url,
                token_address,
                "balanceOf(address)(uint256)",
                top_holder,
            ]
        )

        if top_holder_result.returncode != 0 or not top_holder_result.stdout.strip():
            logger.debug("Whale account has no tokens or balanceOf call failed")
            return False

        # Give the holder address some ETH to pay for gas
        run_command(
            [
                "cast",
                "rpc",
                "--rpc-url",
                rpc_url,
                "anvil_setBalance",
                top_holder,
                "0x21e19e0c9bab2400000",  # 10000 ETH
            ]
        )

        # Transfer tokens from whale
        def transfer_from_whale(impersonated_address):
            run_command(
                [
                    "cast",
                    "send",
                    "--rpc-url",
                    rpc_url,
                    token_address,
                    "transfer(address,uint256)",
                    wallet_address,
                    str(wei_amount),
                    "--from",
                    impersonated_address,
                    "--unlocked",
                ]
            )

        with_impersonation(network, rpc_url, top_holder, transfer_from_whale)
        print(f"*** Successfully transferred {eth_amount} tokens from whale account")
        return True

    except Exception as e:
        logger.debug(f"Error using whale account: {str(e)}")
        return False


def _try_direct_storage_manipulation(
    rpc_url: str, token_address: str, wallet_address: str, wei_amount: int
) -> bool:
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
    print(f"*** Trying direct storage manipulation strategy...")

    try:
        # Get current balance
        current_balance = int(
            run_command(
                [
                    "cast",
                    "call",
                    "--rpc-url",
                    rpc_url,
                    token_address,
                    "balanceOf(address)(uint256)",
                    wallet_address,
                ]
            )
            .stdout.strip()
            .split()[0]
        )

        # Use anvil_setBalance for direct manipulation
        print(f"*** Using anvil to directly set token balance")
        new_balance = current_balance + wei_amount

        # Direct manipulation - works in test environment but not in production chains
        run_command(
            [
                "cast",
                "rpc",
                "--rpc-url",
                rpc_url,
                "anvil_setBalance",
                wallet_address,
                hex(new_balance),
            ]
        )

        # Verify the token balance was changed
        verify_balance = run_command(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc_url,
                token_address,
                "balanceOf(address)(uint256)",
                wallet_address,
            ]
        ).stdout.strip()

        if int(verify_balance) > current_balance:
            print(f"*** Successfully manipulated token balance")
            return True

        return False

    except Exception as e:
        logger.debug(f"Error during direct manipulation: {str(e)}")
        return False


def _try_admin_transfer(
    network: str, rpc_url: str, token_address: str, wallet_address: str, wei_amount: int
) -> bool:
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
    print(f"*** Trying admin transfer strategy...")

    try:
        # Get current balance for verification
        current_balance = int(
            run_command(
                [
                    "cast",
                    "call",
                    "--rpc-url",
                    rpc_url,
                    token_address,
                    "balanceOf(address)(uint256)",
                    wallet_address,
                ]
            )
            .stdout.strip()
            .split()[0]
        )

        # Try using zero address (common admin in test environments)
        admin_address = "0x0000000000000000000000000000000000000000"

        # Impersonate the admin and try transfer
        def admin_transfer(impersonated_address):
            # First give admin some ETH to pay for gas
            run_command(
                [
                    "cast",
                    "rpc",
                    "--rpc-url",
                    rpc_url,
                    "anvil_setBalance",
                    admin_address,
                    "0x56BC75E2D63100000",  # 100 ETH
                ]
            )

            # Try to execute a transfer
            run_command_quiet(
                [
                    "cast",
                    "send",
                    "--rpc-url",
                    rpc_url,
                    token_address,
                    "transfer(address,uint256)",
                    wallet_address,
                    str(wei_amount),
                    "--from",
                    impersonated_address,
                    "--unlocked",
                ]
            )

        with_impersonation(network, rpc_url, admin_address, admin_transfer)

        # Check if the balance increased
        final_balance = run_command(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc_url,
                token_address,
                "balanceOf(address)(uint256)",
                wallet_address,
            ]
        ).stdout.strip()

        if int(final_balance) > current_balance:
            print(f"*** Successfully added tokens using admin account")
            return True

        return False

    except Exception as e:
        logger.debug(f"Error using admin account: {str(e)}")
        return False


def _try_log_scanning(
    rpc_url: str, token_address: str, wallet_address: str, wei_amount: int
) -> bool:
    """
    Try obtaining tokens by scanning logs for holders and impersonating them.

    Args:
        rpc_url: RPC URL to use
        token_address: Token contract address
        wallet_address: Recipient wallet address
        wei_amount: Amount in wei to transfer

    Returns:
        bool: True if successful, False otherwise
    """
    print(f"*** Trying log scanning strategy...")

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
    latest_block = int(
        run_command(["cast", "block", "latest", "-f", "number"]).stdout.strip()
    )
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
            if (
                to_address in done
                or to_address == "0x0000000000000000000000000000000000000000"
            ):
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
                if (
                    wei_pawn_holding > 1000000
                ):  # Small threshold to catch more token holders
                    # Calculate how much to take (90% of their balance, capped at what we still need)
                    wei_to_steal = min(
                        wei_pawn_holding * 9 // 10, wei_amount - wei_amount_transferred
                    )
                    eth_to_steal = run_command(
                        ["cast", "from-wei", str(wei_to_steal)]
                    ).stdout.strip()

                    print(
                        f"*** stealing {eth_to_steal} of {token} from {to_address}..."
                    )

                    # Use the with_impersonation helper
                    def transfer_tokens(impersonated_address):
                        # Give the address some ETH to pay for gas
                        run_command(
                            [
                                "cast",
                                "rpc",
                                "anvil_setBalance",
                                to_address,
                                run_command(
                                    ["cast", "to-hex", "27542757796200000000"]
                                ).stdout.strip(),
                            ]
                        )

                        # Transfer tokens
                        run_command(
                            [
                                "cast",
                                "send",
                                token_address,
                                "transfer(address,uint256)",
                                wallet_address,
                                str(wei_to_steal),
                                "--from",
                                impersonated_address,
                                "--unlocked",
                            ]
                        )

                    # Execute the transfer with impersonation
                    with_impersonation(network, to_address, transfer_tokens)

                    # Update tracking variables
                    wei_amount_transferred += wei_to_steal
                    eth_amount_transferred = run_command(
                        ["cast", "from-wei", str(wei_amount_transferred)]
                    ).stdout.strip()
                    print(
                        f"*** total amount stolen so far: {eth_amount_transferred} of {eth_amount}"
                    )

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
        print(
            f"*** Warning: Could only find {eth_amount_transferred} of requested {eth_amount} tokens"
        )
        print(
            f"*** Missing {remaining_eth} tokens. Try checking more blocks or a different token."
        )
        return False
    return True


def grab_erc20(
    network: str,
    rpc_url: str,
    wallet: str,
    eth_amount: str,
    token: str,
    method: TokenAcquisitionMethod = "all",
) -> bool:
    """
    Get ERC20 tokens for a wallet using specified strategy or trying all available strategies.

    Strategies tried in order:
    1. Direct minting (if token has a mint function)
    2. Transfer from whale account (large holder)
    3. Direct storage manipulation (anvil-only)
    4. Admin account transfer (impersonating zero address)
    5. Log scanning for token holders (partially implemented)

    Args:
        network: Network name
        rpc_url: RPC URL to use
        wallet: Wallet address or name to add tokens to
        eth_amount: Amount of tokens to add (in ETH units)
        token: Token address or name
        method: Specific method to try, or "all" to try all methods in sequence

    Returns:
        bool: True if tokens were successfully added, False otherwise
    """
    wallet_address = address_of(network, wallet)
    token_address = address_of(network, token)

    # Convert to wei
    wei_amount = int(run_command(["cast", "to-wei", eth_amount]).stdout.strip())

    # Check current balance
    wei_balance = (
        run_command(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc_url,
                token_address,
                "balanceOf(address)(uint256)",
                wallet_address,
            ]
        )
        .stdout.strip()
        .split()[0]
    )
    eth_balance = run_command(["cast", "from-wei", wei_balance]).stdout.strip()
    print(f"*** giving {wallet} {eth_amount} erc20 {token} (current: {eth_balance})...")

    # Only try methods that work in test environments if URL suggests we're in one
    is_test_environment = rpc_url.startswith("http://localhost")
    if not is_test_environment and method not in ["logs", "all"]:
        print(f"*** Method {method} requires a test environment but we're on {rpc_url}")
        return False

    # Strategy selection based on method parameter
    if method == "mint" or method == "all":
        if _try_mint_tokens(
            rpc_url, token_address, wallet_address, wei_amount, eth_amount
        ):
            return True

    if method == "whale" or method == "all":
        if _try_whale_transfer(
            network, rpc_url, token_address, wallet_address, wei_amount, eth_amount
        ):
            return True

    if is_test_environment and (method == "storage" or method == "all"):
        if _try_direct_storage_manipulation(
            rpc_url, token_address, wallet_address, wei_amount
        ):
            return True

    if is_test_environment and (method == "admin" or method == "all"):
        if _try_admin_transfer(
            network, rpc_url, token_address, wallet_address, wei_amount
        ):
            return True

    if method == "logs" or method == "all":
        if _try_log_scanning(rpc_url, token_address, wallet_address, wei_amount):
            return True

    print(f"*** Failed to add tokens using method(s): {method}")
    return False
