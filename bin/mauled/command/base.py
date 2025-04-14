"""Base command definitions and registry for MAUL CLI.

This module provides the foundation for command registration and discovery,
consolidating functionality from the previous separate base modules.
"""

import inspect
from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Type, Union

from ..core.logging import get_logger

logger = get_logger()

# Command registry - maps command names to command classes
_commands: Dict[str, Type["Command"]] = {}


class Command(ABC):
    """Base class for all MAUL commands."""

    # These should be overridden by subclasses
    name: str = None  # Command name used in CLI
    help: str = None  # Help text for command

    @classmethod
    @abstractmethod
    def add_arguments(cls, parser):
        """
        Add command-specific arguments to the argument parser.

        Args:
            parser: The argparse parser to add arguments to
        """
        pass

    @classmethod
    @abstractmethod
    def execute(cls, args):
        """
        Execute the command with the given arguments.

        Args:
            args: The parsed command-line arguments

        Returns:
            Command result (implementation-specific)
        """
        pass


def register_command(name=None, help_text=None):
    """
    Decorator to register a command class.

    Args:
        name: Name to register the command under (defaults to class.name)
        help_text: Help text for the command (defaults to class.help)

    Returns:
        Decorator function
    """

    def decorator(cls):
        # Use provided name or class name attribute
        cmd_name = name or cls.name
        if not cmd_name:
            raise ValueError(f"Command {cls.__name__} must define a name")

        # Use provided help text or class help attribute
        cls.help = help_text or cls.help
        if not cls.help:
            cls.help = cls.__name__

        # Register the command
        _commands[cmd_name] = cls
        logger.debug(f"Registered command: {cmd_name}")
        return cls

    return decorator


def get_command(name: str) -> Optional[Type[Command]]:
    """
    Get a command by name.

    Args:
        name: Name of the command to retrieve

    Returns:
        Command class or None if not found
    """
    return _commands.get(name)


def get_all_commands() -> Dict[str, Type[Command]]:
    """
    Get all registered commands.

    Returns:
        Dictionary mapping command names to command classes
    """
    return _commands.copy()


def list_commands() -> List[str]:
    """
    Get a list of all command names.

    Returns:
        List of command names
    """
    return sorted(list(_commands.keys()))


def find_commands_in_module(module):
    """
    Find and register all Command subclasses in a module.

    Args:
        module: Module to search for commands

    Returns:
        List of command classes found
    """
    found_commands = []
    for name, obj in inspect.getmembers(module):
        # Check if it's a class that inherits from Command
        if (
            inspect.isclass(obj)
            and obj != Command
            and issubclass(obj, Command)
            and obj.__module__ == module.__name__
        ):
            found_commands.append(obj)

    return found_commands
