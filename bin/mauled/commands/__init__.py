"""
Command implementations for MAUL CLI.

This package contains all the command implementations for the MAUL CLI.
Each command is implemented as a class that inherits from the Command base class.
"""

# Import all commands to ensure they're registered
from .address import AddressCommand
from .call import CallCommand
from .grant import GrantCommand
from .send import SendCommand
from .sig import SigCommand
from .start import StartCommand
from .steal import StealCommand

__all__ = [
    "AddressCommand",
    "CallCommand",
    "GrantCommand",
    "SendCommand",
    "SigCommand",
    "StartCommand",
    "StealCommand",
]
