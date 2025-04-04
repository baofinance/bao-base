"""
Configuration and fixtures for pytest tests.
"""
import os
import sys
import pytest
from unittest.mock import patch, MagicMock

# Add the project root to the Python path to allow importing local modules
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../..')))

# Root directory of the project
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))

@pytest.fixture
def mock_dotenv():
    """Fixture to mock the dotenv module."""
    with patch('dotenv.load_dotenv') as mock:
        yield mock

@pytest.fixture
def mock_quiet_run_command():
    """Fixture to mock the quiet_run_command function."""
    with patch('bin.anvil.quiet_run_command') as mock:
        # Set up a reasonable default return value
        mock.return_value = MagicMock(
            returncode=0,
            stdout='',
            stderr=''
        )
        yield mock

@pytest.fixture
def mock_run_command():
    """Fixture to mock the run_command function."""
    with patch('bin.anvil.run_command') as mock:
        # Set up a reasonable default return value
        mock.return_value = MagicMock(
            returncode=0,
            stdout='',
            stderr=''
        )
        yield mock

@pytest.fixture
def test_output_dir(tmp_path):
    """Create a temporary output directory for test files."""
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    # Set ABI_DIR environment variable for tests
    old_abi_dir = os.environ.get('ABI_DIR')
    os.environ['ABI_DIR'] = str(output_dir)
    yield output_dir
    # Restore original environment
    if old_abi_dir:
        os.environ['ABI_DIR'] = old_abi_dir
    else:
        del os.environ['ABI_DIR']

@pytest.fixture
def mock_private_key():
    """Fixture to set a mock private key for tests."""
    old_key = os.environ.get('PRIVATE_KEY')
    os.environ['PRIVATE_KEY'] = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'
    yield
    if old_key:
        os.environ['PRIVATE_KEY'] = old_key
    else:
        del os.environ['PRIVATE_KEY']
