"""Parser utilities for MAUL command-line interface.

This consolidates functionality from the previous separate parsers in cli/ and core/.
"""

import argparse
import os
import sys
from typing import Dict, List, Optional, Union

from ..core.logging import get_logger

logger = get_logger()


def create_main_parser() -> argparse.ArgumentParser:
    """Create the main command-line argument parser."""
    parser = argparse.ArgumentParser(
        description="Maul - Blockchain interaction tool", prog="maul"
    )

    # Add global arguments
    parser.add_argument(
        "--verbose",
        "-v",
        action="count",
        default=0,
        help="Increase verbosity (can be used multiple times)",
    )
    parser.add_argument(
        "--quiet", "-q", action="store_true", help="Suppress all output except errors"
    )
    parser.add_argument(
        "--network",
        "-n",
        default="mainnet",
        help="Network to connect to (default: mainnet)",
    )

    return parser


def create_subparsers(parser: argparse.ArgumentParser, commands: Dict) -> Dict:
    """
    Create subparsers for each command.

    Args:
        parser: Main parser to add subparsers to
        commands: Dictionary mapping command names to command classes

    Returns:
        Dict mapping command names to subparsers
    """
    # Set up subparsers
    subparsers = parser.add_subparsers(
        title="commands", dest="command", help="Command to execute"
    )

    # Create a subparser for each command
    parsers = {}
    for name, cmd_class in commands.items():
        cmd_parser = subparsers.add_parser(name, help=cmd_class.help)
        cmd_class.add_arguments(cmd_parser)
        parsers[name] = cmd_parser

    return parsers


def parse_args(
    args: Optional[List[str]] = None, parser: Optional[argparse.ArgumentParser] = None
) -> argparse.Namespace:
    """
    Parse command-line arguments.

    Args:
        args: Command-line arguments (defaults to sys.argv[1:])
        parser: Optional pre-configured parser (creates one if not provided)

    Returns:
        Parsed arguments namespace
    """
    if parser is None:
        parser = create_main_parser()

    return parser.parse_args(args)


def parse_config_file(file_path: str) -> Dict:
    """
    Parse a configuration file.

    Args:
        file_path: Path to the configuration file

    Returns:
        Dictionary containing configuration
    """
    if not os.path.exists(file_path):
        logger.warning(f"Configuration file not found: {file_path}")
        return {}

    try:
        # Determine file type by extension
        if file_path.endswith(".toml"):
            import toml

            return toml.load(file_path)
        elif file_path.endswith(".json"):
            import json

            with open(file_path, "r") as f:
                return json.load(f)
        elif file_path.endswith(".yaml") or file_path.endswith(".yml"):
            import yaml

            with open(file_path, "r") as f:
                return yaml.safe_load(f)
        else:
            logger.warning(f"Unsupported configuration file format: {file_path}")
            return {}
    except Exception as e:
        logger.error(f"Error parsing configuration file {file_path}: {e}")
        return {}
