"""Utility functions for the MAUL package."""

import contextlib
import logging
import os
import subprocess
import sys

logger = logging.getLogger("maul")


def setup_python_paths():
    """
    Set up Python import paths to ensure all MAUL components are accessible.
    This should be called early in the import process.
    """
    # Make sure the project root is in the Python path
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
        logger.debug(f"Added project root to sys.path: {project_root}")

    # Make sure the maul package itself is importable
    maul_dir = os.path.dirname(os.path.abspath(__file__))
    if maul_dir not in sys.path:
        sys.path.insert(0, maul_dir)
        logger.debug(f"Added maul package directory to sys.path: {maul_dir}")

    # Make the bin directory importable by name
    bin_dir = os.path.join(project_root, "bin")
    if os.path.isdir(bin_dir) and bin_dir not in sys.path:
        sys.path.insert(0, bin_dir)
        logger.debug(f"Added bin directory to sys.path: {bin_dir}")

    logger.debug(f"Complete sys.path after setup: {sys.path}")


# Import directly from the renamed core_utils
from bin.maul.utils import (address_of, bcinfo, get_function_info,
                            quiet_run_command, run_command)

# Import from the canonical implementation
from maul.core.eth import with_impersonation


# Domain-specific utility function
def role_number_of(network, role, on):
    """
    Get the numeric value of a role on a contract.

    Args:
        network: The network name
        role: The role name or ID
        on: The contract to check

    Returns:
        The numeric role ID
    """
    if role.startswith("0x") or role.isdigit():
        return role
    on_address = address_of(network, on)
    result = run_command(["cast", "call", on_address, f"{role}()(uint256)"])
    output = result.stdout.strip().split()
    if not output:
        raise ValueError(f"Role {role} not found on {on}")
    return output[0]


# Re-export these functions
__all__ = [
    "run_command",
    "quiet_run_command",
    "address_of",
    "bcinfo",
    "get_function_info",
    "with_impersonation",
    "role_number_of",
]
