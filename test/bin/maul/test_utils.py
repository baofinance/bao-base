"""Test the core utility functions."""

# Import test utilities and registry
from test.utils.test_helpers import CommandResult, SubprocessMock, setup_test_registry
from unittest.mock import patch

import pytest

from maul.registry import reset_registries

# Import directly from implementation source
from maul.utils import (
    address_of,
    quiet_run_command,
    reset_subprocess_runner,
    set_subprocess_runner,
)


# Setup/teardown for tests
@pytest.fixture
def subprocess_mock():
    """Provide a mock subprocess implementation for tests."""
    mock = SubprocessMock()
    _original_runner = set_subprocess_runner(mock.run)  # Add underscore prefix
    yield mock
    reset_subprocess_runner()


@pytest.fixture
def test_registry():
    """Set up a test registry with predefined addresses."""
    registry = setup_test_registry()
    yield registry
    reset_registries()  # Clean up after test


# Test quiet_run_command function
def test_quiet_run_command(subprocess_mock):
    # Configure the mock
    subprocess_mock.set_response("echo hello", CommandResult(stdout="Command output", stderr="", returncode=0))

    # Call the function
    result = quiet_run_command(["echo", "hello"])

    # Verify the result
    assert result.returncode == 0
    assert result.stdout == "Command output"
    assert result.stderr == ""
    assert ["echo", "hello"] in subprocess_mock.commands_run


# Test address_of function with mocking
def test_address_of():
    # Use patch to mock the resolution functions instead of registry
    with patch("bin.maul.utils.resolution_address_of") as mock_resolve:
        # Test with direct hex address
        mock_resolve.side_effect = lambda network, name: (name if name.startswith("0x") else "0xmocked_address")

        # Test with direct hex address
        address = "0x1234567890123456789012345678901234567890"
        result = address_of("mainnet", address)
        assert result == address

        # Test with name lookup
        result = address_of("mainnet", "token_name")
        assert result == "0xmocked_address"
