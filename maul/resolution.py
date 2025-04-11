"""Address resolution functionality for MAUL."""

import json
import os
from typing import Dict, Optional, Union

from bin.maul.logging import get_logger
from bin.maul.utils import run_command

logger = get_logger()


def is_hex_address(address: str) -> Optional[str]:
    """
    Check if the given string is a valid Ethereum address.

    Args:
        address: Address to check

    Returns:
        The address if valid, None otherwise
    """
    if not address:
        return None

    # Validate Ethereum address format
    if isinstance(address, str) and address.startswith("0x") and len(address) == 42:
        try:
            # Check if the hex part is valid
            int(address[2:], 16)
            return address
        except ValueError:
            return None
    return None


def resolve_me_address() -> Optional[str]:
    """
    Resolve the 'me' address using the PRIVATE_KEY environment variable.

    Returns:
        The resolved address or None if not available
    """
    private_key = os.environ.get("PRIVATE_KEY")
    if not private_key:
        logger.debug("No PRIVATE_KEY environment variable available")
        return None

    try:
        # Use our local minimal command runner
        result = run_command(["cast", "wallet", "address", "--private-key", private_key])
        address = result.stdout.strip()
        logger.debug(f"Resolved 'me' to {address}")
        return address
    except Exception as e:
        logger.error(f"Error resolving 'me' address: {e}")
        return None


def resolve_blockchain_address(network: str, name: str) -> Optional[str]:
    """
    Try to resolve an address using on-chain contracts.

    Args:
        network: Network name
        name: Name to resolve

    Returns:
        Resolved address or None if not found
    """
    # This would use ENS or similar on-chain resolution
    try:
        # Try using ENS-like resolution if on supported networks
        if network in ["mainnet", "goerli", "sepolia"]:
            result = run_command(["cast", "resolve-name", name])
            if result.returncode == 0:
                address = result.stdout.strip()
                logger.debug(f"Resolved {name} to {address} using blockchain lookup")
                return address
    except Exception as e:
        logger.debug(f"Error resolving via blockchain: {e}")

    return None


def resolve_deployment_log_address(name: str, log_path: Optional[str] = None) -> Optional[str]:
    """
    Look up address in deployment log.

    Args:
        name: Contract or account name
        log_path: Optional path to deployment log file

    Returns:
        The resolved address if found, None otherwise
    """
    if not log_path:
        log_path = os.path.join(os.getenv("BAO_BASE_DIR", "."), "log", "deploy-local.log")

    if not os.path.isfile(log_path):
        return None

    try:
        with open(log_path) as f:
            data = json.load(f)
            addresses = data.get("addresses", {})
            if name in addresses:
                address = addresses[name]
                logger.debug(f"Resolved {name} to {address} from deployment log")
                return address
    except Exception as e:
        logger.debug(f"Error reading deployment log: {e}")

    return None


def address_of(network: str, name: str) -> str:
    """
    Get address from name or return if already an address.

    This is the canonical implementation that all other functions should use.

    Resolution order:
    1. Check if it's already a hex address
    2. Check if it's 'me' (current user)
    3. Try blockchain resolution (e.g. ENS)
    4. Try deployment logs
    5. Return original input if not resolvable

    Args:
        network: Network name
        name: Name or address to resolve

    Returns:
        Resolved address or original name if not found
    """
    # If name is None, return None immediately
    if name is None:
        return None

    # If it's already an address, return it
    if isinstance(name, str):
        # First check if it's already a hex address
        if hex_address := is_hex_address(name):
            return hex_address

        # Special case for 'me'
        if name == "me":
            if address := resolve_me_address():
                return address
            logger.warning("Failed to resolve 'me' - no private key set")
            return name

    # Try blockchain resolution first (most authoritative)
    if address := resolve_blockchain_address(network, name):
        return address

    # Try deployment logs
    if address := resolve_deployment_log_address(name):
        return address

    # Return the original input if not resolved
    logger.debug(f"Could not resolve '{name}' on {network}, returning as-is")
    return name


def bcinfo(
    network: Optional[str] = None, name: Optional[str] = None, field: str = "address"
) -> Union[Dict, str]:
    """
    Get information about the current blockchain or resolve a contract address.

    This consolidated implementation handles both blockchain info retrieval
    and contract address resolution without circular dependencies.

    Args:
        network: Network name
        name: Optional contract name
        field: Field to retrieve

    Returns:
        Contract information or blockchain info
    """
    # If no name provided, return general blockchain info
    if name is None:
        try:
            result = run_command(["cast", "chain-id"])
            chain_id = int(result.stdout.strip())

            result = run_command(["cast", "block-number"])
            block_number = int(result.stdout.strip())

            return {"chain_id": chain_id, "block_number": block_number}
        except Exception as e:
            logger.error(f"Failed to get blockchain info: {e}")
            return {}

    # Handle name resolution directly (without calling address_of)
    # This avoids duplicating the resolution logic while eliminating circular dependencies
    if name == "me":
        return resolve_me_address() or name
    elif is_hex_address(name):
        return name
    elif address := resolve_blockchain_address(network, name):
        return address
    elif address := resolve_deployment_log_address(name):
        return address

    # Return the original input if not resolved
    logger.debug(f"Could not resolve '{name}' on {network}, returning as-is")
    return name


# Export both functions in __all__
__all__ = [
    "address_of",
    "bcinfo",
    "is_hex_address",
    "resolve_me_address",
    "resolve_blockchain_address",
    "resolve_deployment_log_address",
]
