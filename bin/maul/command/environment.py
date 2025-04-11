"""Environment and path setup functions for MAUL."""

import logging
import os
import sys

logger = logging.getLogger("maul")


def setup_python_paths():
    """
    Set up Python import paths to ensure all MAUL components are accessible.

    This ensures the project root, bin directory, and other essential
    directories are in the Python path.
    """
    # Make sure the project root is in the Python path
    project_root = os.path.abspath(
        os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
    )
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
        logger.debug(f"Added project root to sys.path: {project_root}")

    # Make the bin directory importable by name
    bin_dir = os.path.join(project_root, "bin")
    if os.path.isdir(bin_dir) and bin_dir not in sys.path:
        sys.path.insert(0, bin_dir)
        logger.debug(f"Added bin directory to sys.path: {bin_dir}")

    # Make sure maul package is importable
    maul_dir = os.path.join(project_root, "maul")
    if os.path.isdir(maul_dir) and maul_dir not in sys.path:
        sys.path.insert(0, maul_dir)
        logger.debug(f"Added maul directory to sys.path: {maul_dir}")
