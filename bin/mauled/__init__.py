"""
MAUL - Command-line tools for BAO Finance projects.

This package provides command infrastructure and discovery capabilities.
"""

# Export commonly used components - no implementation here
# Import the registry functions from the actual command base module
from .command.base import Command, get_all_commands, get_command, register_command
from .core.logging import get_logger

__all__ = [
    "Command",
    "get_all_commands",
    "get_command",
    "register_command",
    "get_logger",
]
