"""Command loading functionality for MAUL."""

import importlib
import importlib.util
import logging
import os
import sys
from typing import Any, Dict, List, Optional

from ..exceptions import (CommandLoadError, CommandNotFoundError,
                          ConfigLoadError)

logger = logging.getLogger("maul")


def load_config():
    """
    Load the maul.toml configuration file.

    Returns:
        dict: Configuration settings

    Raises:
        ConfigLoadError: If there's an error loading the configuration
    """
    try:
        import tomli
    except ImportError:
        # For Python < 3.11 that doesn't have tomli in stdlib
        try:
            import tomllib as tomli
        except ImportError:
            logger.warning("Could not import tomli or tomllib. Using default config.")
            return {"command_dirs": ["maul/commands"], "default_network": "mainnet"}

    # Default configuration - none! (for now at least)
    config = {
        # "command_dirs": ["maul/commands"],
        # "default_network": "mainnet"
    }

    # Look in these locations for config, in order of preference
    config_paths = [
        os.path.join(os.environ.get("BAO_BASE_DIR", "."), "maul/maul.toml"),  # Maul directory
        os.path.join(os.environ.get("BAO_BASE_DIR", "."), "maul.toml"),  # Project root (legacy)
        os.path.join(os.path.expanduser("~"), "maul.toml"),  # User home directory
    ]

    # Load the first config file found
    for path in config_paths:
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:  # Note: 'rb' mode required for tomli
                    user_config = tomli.load(f)
                    config.update(user_config)
                    logger.debug(f"Loaded config from {path}")
                    break
            except Exception as e:
                msg = f"Failed to load config from {path}: {e}"
                logger.warning(msg)
                raise ConfigLoadError(msg) from e

    return config


def import_all_commands():
    """
    Import all command modules to register commands via decorators.

    Raises:
        CommandLoadError: If there's an error loading commands
    """
    config = load_config()

    # Updated to point to the new command locations
    command_dirs = config.get("command_dirs", ["maul/commands"])

    # Process each directory in the config
    for command_dir in command_dirs:
        # Make sure the path is absolute

        if not os.path.isdir(command_dir):
            logger.error(f"Command directory not found: {command_dir}")
            exit(1)

        logger.info1(f"Importing commands from {command_dir}")

        # Find all Python files in the directory except __init__.py and base.py
        for item in os.listdir(command_dir):
            if item.endswith(".py") and item not in ["__init__.py", "base.py", "loader.py"]:
                module_path = os.path.join(command_dir, item)
                module_name = os.path.splitext(item)[0]

                try:
                    # Import using the maul.commands namespace
                    spec = importlib.util.spec_from_file_location(
                        f"maul.commands.{module_name}", module_path
                    )
                    if spec and spec.loader:
                        module = importlib.util.module_from_spec(spec)
                        sys.modules[spec.name] = module
                        spec.loader.exec_module(module)
                        logger.debug(f"Imported command module: {module_name}")
                except Exception as e:
                    error_msg = f"Error importing command module {module_name}: {e}"
                    logger.error(error_msg)
                    raise CommandLoadError(error_msg) from e
