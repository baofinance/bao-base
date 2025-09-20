"""Pytest configuration for regression system tests."""

import sys
from pathlib import Path

import pytest


# Add the bin directory to Python path so we can import modules
@pytest.fixture(autouse=True)
def setup_python_path():
    bin_dir = Path(__file__).parent.parent.parent / "bin"
    if str(bin_dir) not in sys.path:
        sys.path.insert(0, str(bin_dir))
