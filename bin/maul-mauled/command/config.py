"""Configuration and project discovery for MAUL."""

import os
import sys
import json
from pathlib import Path
from typing import Dict

from ..core.logging import get_logger

logger = get_logger()


def setup_project_paths(config=None):
    """
    Configure Python paths for all projects in the ecosystem.

    Args:
        config: Optional configuration dictionary
    """
    # Start with current project
    projects = [os.getcwd()]

    # Add BAO_BASE_DIR if different
    bao_base_dir = os.environ.get("BAO_BASE_DIR")
    if bao_base_dir and bao_base_dir not in projects:
        projects.append(bao_base_dir)

    # Add dependencies from config
    if config and "dependencies" in config:
        for dep_name in config["dependencies"]:
            # Resolve dependency path relative to BAO_BASE_DIR
            if bao_base_dir:
                dep_path = Path(bao_base_dir).parent / dep_name
                if dep_path.exists() and str(dep_path) not in projects:
                    projects.append(str(dep_path))

    # Add all projects to Python path
    for project in projects:
        if project not in sys.path:
            sys.path.insert(0, project)

    return projects


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
