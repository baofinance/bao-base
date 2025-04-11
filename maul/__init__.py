"""
Maul package for Bao Finance tools.
This package provides utilities and commands for interacting with Bao Finance contracts.
"""

# Version of the package
__version__ = "0.1.0"

# Import setup function from bin.maul
from bin.maul.environment import setup_python_paths

# Reexport the setup function
__all__ = ['setup_python_paths']
