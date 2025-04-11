"""Command discovery for MAUL."""

import importlib
import importlib.util
import os
import pkgutil
import sys
import traceback

from .base import get_all_commands
from ..core.logging import get_logger

logger = get_logger()


def discover_commands(config):
    """
    Discover all available commands across all projects.

    This uses dynamic imports to avoid static dependencies on maul packages.
    """
    # Get project directories where commands can be found
    project_dirs = [os.getcwd()]  # Start with current directory

    # Add bao-base if specified
    bao_base_dir = os.environ.get("BAO_BASE_DIR")
    if bao_base_dir and bao_base_dir != project_dirs[0]:
        project_dirs.append(bao_base_dir)

    # Add specified dependencies from config
    if "dependencies" in config and isinstance(config["dependencies"], list):
        for dep in config["dependencies"]:
            dep_path = os.path.normpath(
                os.path.join(os.path.dirname(bao_base_dir), dep)
            )
            if os.path.isdir(dep_path) and dep_path not in project_dirs:
                project_dirs.append(dep_path)

    logger.debug(f"Projects to scan for commands: {project_dirs}")

    # Ensure all project directories are in Python path
    for project_dir in project_dirs:
        if project_dir not in sys.path:
            sys.path.insert(0, project_dir)
            logger.debug(f"Added to Python path: {project_dir}")

    # Dynamically import command modules from each project
    for project_dir in project_dirs:
        commands_dir = os.path.join(project_dir, "maul", "commands")
        if not os.path.isdir(commands_dir):
            logger.debug(f"No commands directory at {commands_dir}")
            continue

        logger.debug(f"Scanning for command modules in {commands_dir}")

        # Dynamically import each Python module
        for _, name, is_pkg in pkgutil.iter_modules([commands_dir]):
            if not is_pkg and name not in ["base", "loader", "__init__"]:
                try:
                    # Construct full module name including project-specific path
                    module_name = f"maul.commands.{name}"
                    logger.debug(f"Importing module: {module_name}")
                    importlib.import_module(module_name)
                except Exception as e:
                    logger.error(f"Failed to import command module {module_name}: {e}")
                    logger.debug(traceback.format_exc())

    # Return all registered commands from the central registry
    commands = get_all_commands()
    logger.debug(f"Discovered {len(commands)} commands: {', '.join(commands.keys())}")
    return commands
