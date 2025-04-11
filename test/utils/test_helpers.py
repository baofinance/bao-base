"""Test utilities for MAUL tests."""

import unittest.mock
from typing import Dict, Optional

from bin.maul.registry import MemoryRegistry, add_registry, reset_registries


class CommandResult:
    """
    Result of a command execution for testing.

    This class mimics subprocess.CompletedProcess for test assertions.
    """

    def __init__(self, stdout="", stderr="", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode

    def __repr__(self):
        return f"CommandResult(returncode={self.returncode})"


class SubprocessMock:
    """Mock implementation of subprocess functions for testing."""

    def __init__(self, responses: Dict[str, CommandResult] = None):
        """
        Initialize with pre-configured responses.

        Args:
            responses: Dictionary mapping command strings to CommandResult objects
        """
        self.responses = responses or {}
        self.commands_run = []

    def run(self, cmd_list, capture_output=True, check=True, text=True, **kwargs):
        """Mock implementation of subprocess.run"""
        cmd_str = " ".join(cmd_list)
        self.commands_run.append(cmd_list)

        # Look for exact command match
        if cmd_str in self.responses:
            return self.responses[cmd_str]

        # Try partial matching for flexibility
        for cmd_pattern, result in self.responses.items():
            if all(part in cmd_str for part in cmd_pattern.split()):
                return result

        # Default response if nothing matched
        return CommandResult(stdout="", stderr="", returncode=0)

    def set_response(self, command: str, result: CommandResult):
        """Set a response for a specific command."""
        self.responses[command] = result

    def clear(self):
        """Clear recorded commands and responses."""
        self.commands_run = []
        self.responses = {}


class NetworkContextMock(MemoryRegistry):
    """Mock for network context including registry of addresses."""

    def __init__(self, addresses: Dict[str, str] = None):
        """
        Initialize with pre-configured addresses.

        Args:
            addresses: Dictionary mapping names to addresses
        """
        super().__init__(name="test-registry", addresses=addresses or {})
        self.lookup_attempts = []

    def lookup_address(self, network: str, name: str) -> Optional[str]:
        """
        Mock implementation of address lookup.

        Args:
            network: Network name
            name: Contract or account name

        Returns:
            Corresponding address or name if not found
        """
        self.lookup_attempts.append((network, name))

        # Use the MemoryRegistry implementation
        result = super().lookup_address(network, name)

        # For testing, if not found, return the name itself
        return result if result else name


# Registry fixtures for testing
def setup_test_registry(addresses=None):
    """
    Set up a test registry with predefined addresses.

    Args:
        addresses: Dictionary of name:address mappings

    Returns:
        NetworkContextMock: Configured registry
    """
    # Reset existing registries
    reset_registries()

    # Create and add test registry
    registry = NetworkContextMock(
        addresses
        or {
            "baomultisig": "0x8765fda26e2f80c98fe65a2f9ee192ca1e03d75d",
            "token_name": "0xabcdef1234567890abcdef1234567890abcdef12",
            "me": "0xdefault_address_for_tests",
        }
    )

    # Add at position 0 to ensure it's checked first
    add_registry(registry, 0)

    return registry


def setup_test_environment():
    """Set up a complete test environment with mocked command execution."""
    # Create a subprocess mock
    subprocess_mock = SubprocessMock(
        {
            "cast balance": CommandResult(
                stdout="1000000000000000000", stderr="", returncode=0
            ),
            "cast to-wei": CommandResult(
                stdout="1000000000000000000", stderr="", returncode=0
            ),
            "cast from-wei": CommandResult(stdout="1.0", stderr="", returncode=0),
            "cast to-hex": CommandResult(
                stdout="0x3782dace9d900000", stderr="", returncode=0
            ),
            "cast call": CommandResult(stdout="1", stderr="", returncode=0),
            "cast send": CommandResult(stdout="0xtxhash", stderr="", returncode=0),
            "cast rpc anvil_impersonateAccount": CommandResult(returncode=0),
            "cast rpc anvil_stopImpersonatingAccount": CommandResult(returncode=0),
            "cast rpc anvil_setBalance": CommandResult(returncode=0),
        }
    )

    # Define address mappings for resolution mocking
    address_mappings = {
        "baomultisig": "0x8765fda26e2f80c98fe65a2f9ee192ca1e03d75d",
        "token_name": "0xabcdef1234567890abcdef1234567890abcdef12",
        "me": "0xdefault_address_for_tests",
        "contract": "0x1111222233334444555566667777888899990000",
        "recipient": "0x2222333344445555666677778888999900001111",
        "impersonator": "0x3333444455556666777788889999000011112222",
        "ADMIN_ROLE": "0x0000000000000000000000000000000000000000000000000000000000000001",
    }

    # Create patches including a patch for address_of to return predefined values
    def some_func(x):
        return x + 1

    # Replace lambda with proper function definition
    def address_resolver(network, name):
        return address_mappings.get(name, name if name.startswith("0x") else name)

    patches = {
        "subprocess_runner": unittest.mock.patch(
            "bin.maul.utils._subprocess_runner", subprocess_mock.run
        ),
        "role_number_of": unittest.mock.patch(
            "maul.utils.role_number_of", return_value="1"
        ),
        "address_of": unittest.mock.patch(
            "bin.maul.utils.address_of", side_effect=address_resolver
        ),
        "resolution_address_of": unittest.mock.patch(
            "maul.resolution.address_of", side_effect=address_resolver
        ),
    }

    return {
        "address_mappings": address_mappings,
        "subprocess_mock": subprocess_mock,
        "patches": patches,
    }
