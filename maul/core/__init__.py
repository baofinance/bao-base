"""
Core functionality for maul commands.

Re-exports from specialized modules for command use.
"""

# Import directly from local modules instead of bin.maul
from .formatting import format_call_result, parse_sig
from .eth import grab, grab_erc20

# Don't import from bin.maul.core to avoid circular imports
import logging

# Local logger implementation
def get_logger():
    """Get the logger for maul core modules."""
    return logging.getLogger("maul")

# Explicit exports list - don't include imports from bin.maul
__all__ = [
    # Local implementations
    'get_logger',

    # Ethereum operations
    'grab',
    'grab_erc20',

    # Formatting utilities
    'format_call_result',
    'parse_sig',
]
