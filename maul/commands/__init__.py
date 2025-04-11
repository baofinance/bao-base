"""Command modules for MAUL."""

# Import each command explicitly to ensure they're registered
from maul.commands.call import CallCommand
from maul.commands.decode import DecodeCommand
from maul.commands.format import FormatCommand
from maul.commands.grant import GrantCommand
from maul.commands.resolve import ResolveCommand
from maul.commands.send import SendCommand
from maul.commands.sig import SigCommand
from maul.commands.start import StartCommand
from maul.commands.steal import StealCommand

__all__ = [
    "CallCommand",
    "GrantCommand",
    "SendCommand",
    "SigCommand",
    "StartCommand",
    "StealCommand",
    "DecodeCommand",
    "FormatCommand",
    "ResolveCommand",
    "VerbosityCommand",
]

# Import and re-export the command registry functions from the new location
from bin.maul.base import (Command, get_all_commands, get_command,
                           register_command)

from .loader import import_all_commands, load_config

# Import all command modules when this module is imported
try:
    import_all_commands()
except Exception as e:
    import logging

    logger = logging.getLogger("maul")
    logger.warning(f"Error loading commands: {e}")
