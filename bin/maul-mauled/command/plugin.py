import configparser
import importlib
import logging
import os
import sys
from pathlib import Path

logger = logging.getLogger("maul")


class PluginManager:
    """Manages discovery and loading of maul command plugins"""

    # Dictionary of registered commands
    _commands = {}

    @classmethod
    def find_config_files(cls):
        """Find all .maul config files in the project hierarchy"""
        configs = []

        # Start with current directory
        cwd = Path.cwd()

        # Traverse up the directory tree
        while cwd.exists():
            config_file = cwd / ".maul"
            if config_file.exists():
                configs.append(config_file)
                logger.debug(f"Found config file: {config_file}")

            # Go up one level
            parent = cwd.parent
            if parent == cwd:  # Reached root
                break
            cwd = parent

        return configs

    @classmethod
    def discover_plugins(cls):
        """Discover plugins from config files and register commands"""
        configs = cls.find_config_files()
        plugin_paths = []

        # Add core commands path
        module_dir = Path(__file__).parent.parent
        plugin_paths.append(str(module_dir / "commands"))

        for config in configs:
            # Parse config file
            parser = configparser.ConfigParser()
            parser.read(config)

            if "plugins" in parser and "paths" in parser["plugins"]:
                # Get paths relative to config file
                base_dir = config.parent
                paths = parser["plugins"]["paths"].split(":")

                for path in paths:
                    full_path = (base_dir / path).resolve()
                    if full_path.exists():
                        plugin_paths.append(str(full_path))
                        logger.debug(f"Found plugin path: {full_path}")

        # Add paths to Python path for importing
        for path in plugin_paths:
            if path not in sys.path:
                sys.path.append(path)

        # Import and process all plugins
        cls._load_plugins(plugin_paths)

    @classmethod
    def _load_plugins(cls, plugin_paths):
        """Import and load commands from specified paths"""
        from .base import Command

        for path in plugin_paths:
            try:
                path_obj = Path(path)

                # Skip if not a directory
                if not path_obj.is_dir():
                    continue

                # Try to find python modules
                for py_file in path_obj.glob("**/*.py"):
                    # Skip __init__.py and similar files
                    if py_file.name.startswith("__"):
                        continue

                    # Convert file path to module path
                    rel_path = py_file.relative_to(path_obj.parent)
                    module_name = str(rel_path.with_suffix("")).replace(os.sep, ".")

                    try:
                        # Import the module
                        logger.debug(f"Attempting to import module: {module_name}")
                        module = importlib.import_module(module_name)

                        # Find Command subclasses in the module
                        for attr_name in dir(module):
                            attr = getattr(module, attr_name)

                            # Check if it's a Command subclass
                            if (
                                isinstance(attr, type)
                                and issubclass(attr, Command)
                                and attr is not Command
                                and attr.name
                            ):
                                cls.register_command(attr)
                    except ImportError as e:
                        logger.debug(f"Failed to import {module_name}: {e}")
            except Exception as e:
                logger.debug(f"Error loading plugins from {path}: {e}")

    @classmethod
    def register_command(cls, command_class):
        """Register a command class"""
        logger.debug(f"Registering command: {command_class.name}")

        # Register the main command name
        cls._commands[command_class.name] = command_class

        # Register all aliases
        for alias in getattr(command_class, "aliases", []):
            logger.debug(f"Registering alias: {alias} -> {command_class.name}")
            cls._commands[alias] = command_class

    @classmethod
    def get_commands(cls):
        """Get all registered commands"""
        return cls._commands
