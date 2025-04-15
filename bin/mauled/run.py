#!/usr/bin/env python3
"""Main entry point for the maul command-line tool."""
import argparse
import os
import sys
from typing import List, Optional

from .command.base import get_all_commands, get_command
from .command.config import parse_config_file  # Now correctly imports from config.py
from .command.discovery import discover_commands
from .command.parser import create_main_parser, create_subparsers
from .core.logging import configure_logging, get_logger
from .exceptions import CommandLoadError, CommandNotFoundError

# Get the logger
logger = get_logger()


def create_parser() -> argparse.ArgumentParser:
    """Create the main command-line parser."""
    parser = create_main_parser()  # Use consolidated parser

    # Register all commands
    commands = get_all_commands()
    create_subparsers(parser, commands)  # Use consolidated parser function

    return parser


def main(args: Optional[List[str]] = None) -> int:
    """
    Main entry point for the maul command-line tool.

    Args:
        args: Command-line arguments (defaults to sys.argv[1:])

    Returns:
        int: Exit code
    """
    try:
        # Ensure commands are properly discovered and registered
        # Load config
        config_file = os.path.join(os.getcwd(), "maul.config")
        config = parse_config_file(config_file) if os.path.exists(config_file) else {}

        # Discover commands - this triggers all the registration code
        discover_commands(config)

        # Now continue with parser creation and command execution
        parser = create_parser()
        parsed_args = parser.parse_args(args)

        # set up logging
        configure_logging(parsed_args.verbose, parsed_args.quiet)

        # Execute the command if one was specified
        if not parsed_args.command:
            parser.print_help()
            return 1

        # Get the command and execute it
        command = get_command(parsed_args.command)
        if not command:
            raise CommandNotFoundError(f"Command not found: {parsed_args.command}")

        # Execute command and ignore the return value - commands should print their own output
        command.execute(parsed_args)

        # Return success if no exceptions were raised
        return 0

    except CommandNotFoundError as e:
        logger.error(str(e))
        return 1

    except CommandLoadError as e:
        logger.error(f"Error loading commands: {e}")
        return 1

    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
