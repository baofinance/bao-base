"""
Pytest tests for the anvil.py script.

These tests correspond to the BATS tests in test/bin/anvil.bats
but use proper Python testing approaches.
"""

import json
import os
import sys
from unittest.mock import MagicMock, patch

import pytest
# Import utility functions
from utils import calculate_error_selector, create_mock_abi

# Import the anvil module directly
from bin import anvil


def test_help_info(capsys):
    """Test that anvil.py shows help information."""
    # Capture the output
    with pytest.raises(SystemExit):
        with patch.object(sys, "argv", ["anvil.py", "--help"]):
            anvil.main()

    # Get captured output
    captured = capsys.readouterr()

    # Verify expectations
    assert "usage: anvil.py" in captured.out


def test_sig_command(mock_quiet_run_command, mock_run_command, test_output_dir):
    """Test the sig command shows function signature correctly."""
    # Create mock ABI file
    abi_content = [
        {
            "name": "transfer",
            "type": "function",
            "inputs": [
                {"name": "recipient", "type": "address"},
                {"name": "amount", "type": "uint256"},
            ],
            "outputs": [{"name": "success", "type": "bool"}],
        }
    ]
    create_mock_abi(test_output_dir, "ERC20", abi_content)

    # Mock the find and jq commands to return our test ABI
    def mock_command(cmd):
        if isinstance(cmd, list) and len(cmd) > 1:
            # Mock find command
            if "find" in cmd and "ERC20.json" in " ".join(cmd):
                return MagicMock(
                    returncode=0, stdout=str(test_output_dir / "ERC20.json"), stderr=""
                )
            # Mock jq command for function info
            elif "jq" in cmd and "transfer" in " ".join(cmd):
                return MagicMock(
                    returncode=0, stdout=json.dumps(abi_content[0]), stderr=""
                )
        # Default for other commands
        return MagicMock(returncode=0, stdout="", stderr="")

    mock_quiet_run_command.side_effect = mock_command
    mock_run_command.side_effect = mock_command

    # Instead of running main(), directly test the get_function_info function
    # to verify signature extraction
    with patch("bin.anvil.run_command", mock_run_command):
        func_info = anvil.get_function_info("ERC20", "transfer")

        # Verify function info was extracted correctly
        assert func_info["signature"] == "transfer(address,uint256)"
        assert func_info["param_types"] == ["address", "uint256"]
        assert len(func_info["inputs"]) == 2
        assert len(func_info["outputs"]) == 1
        assert func_info["inputs"][0]["name"] == "recipient"
        assert func_info["inputs"][1]["name"] == "amount"
        assert func_info["outputs"][0]["name"] == "success"

        # Make sure the mock was called
        mock_run_command.assert_called()


def test_address_of_resolves_baomultisig(mock_run_command, mock_private_key):
    """Test that address_of resolves 'baomultisig' to an address."""
    # Mock the return value for cast wallet address
    mock_address = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
    mock_run_command.return_value.stdout = mock_address

    # Call the function under test
    result = anvil.address_of("mainnet", "baomultisig")

    # Check that address_of returns an Ethereum address
    assert result.startswith("0x")
    assert len(result) == 42
    assert all(c in "0123456789abcdefABCDEF" for c in result[2:])


def test_decode_custom_error(test_output_dir, mock_quiet_run_command):
    """Test that decode_custom_error correctly decodes a known error."""
    # Create mock ABI file
    abi_content = [
        {
            "name": "InvalidValue",
            "type": "error",
            "inputs": [{"name": "value", "type": "uint256"}],
        }
    ]
    create_mock_abi(test_output_dir, "TestContract", abi_content)

    # Mock keccak calculation for error selector
    error_sig = "0x12345678"  # First 4 bytes of the selector
    error_data = (
        f"{error_sig}000000000000000000000000000000000000000000000000000000000000002a"
    )

    # Set up mocks for find and jq commands
    def mock_command(cmd):
        if "find" in cmd and "TestContract.json" in " ".join(cmd):
            return MagicMock(
                returncode=0,
                stdout=str(test_output_dir / "TestContract.json"),
                stderr="",
            )
        elif "find" in cmd and "*.json" in " ".join(cmd):
            return MagicMock(
                returncode=0,
                stdout=str(test_output_dir / "TestContract.json"),
                stderr="",
            )
        elif "jq" in cmd:
            return MagicMock(returncode=0, stdout=json.dumps(abi_content[0]), stderr="")
        elif "cast" in cmd and "keccak" in cmd:
            return MagicMock(returncode=0, stdout=error_sig, stderr="")
        elif "cast" in cmd and "calldata" in cmd:
            return MagicMock(returncode=0, stdout="42", stderr="")
        else:
            return MagicMock(returncode=0, stdout="", stderr="")

    mock_quiet_run_command.side_effect = mock_command

    # Call the function under test
    decoded, raw = anvil.decode_custom_error(error_data)

    # Verify the error is properly decoded
    assert "Error: InvalidValue" in decoded
    assert "[from TestContract]" in decoded
    assert raw == error_data


def test_parse_sig_handles_signatures(
    test_output_dir, mock_quiet_run_command, mock_run_command
):
    """Test that parse_sig handles both signature formats correctly."""
    # Create mock ABI file
    abi_content = [
        {
            "name": "approve",
            "type": "function",
            "inputs": [
                {"name": "spender", "type": "address"},
                {"name": "amount", "type": "uint256"},
            ],
            "outputs": [{"name": "success", "type": "bool"}],
        }
    ]
    create_mock_abi(test_output_dir, "Token", abi_content)

    # Set up mocks
    def mock_command(cmd):
        if "find" in cmd:
            return MagicMock(
                returncode=0, stdout=str(test_output_dir / "Token.json"), stderr=""
            )
        elif "jq" in cmd:
            return MagicMock(returncode=0, stdout=json.dumps(abi_content[0]), stderr="")
        else:
            return MagicMock(returncode=0, stdout="", stderr="")

    mock_quiet_run_command.side_effect = mock_command
    mock_run_command.side_effect = mock_command

    # Test with full function signature
    with patch("bin.anvil.run_command", mock_run_command):
        sig, param_types = anvil.parse_sig("mainnet", "transfer(address,uint256)")
        assert sig == "transfer(address,uint256)"
        assert param_types == ["address", "uint256"]

        # Test with Contract.function format
        sig, param_types = anvil.parse_sig("mainnet", "Token.approve")
        assert sig == "approve(address,uint256)"
        assert param_types == ["address", "uint256"]


def test_set_verbosity():
    """Test that set_verbosity correctly sets log levels."""
    # Test level 0 (WARNING)
    anvil.set_verbosity(0)
    assert anvil.logger.level == anvil.logging.WARNING
    assert anvil.logger.isEnabledFor(anvil.logging.WARNING)
    assert not anvil.logger.isEnabledFor(anvil.logging.INFO)

    # Test level 1 (INFO)
    anvil.set_verbosity(1)
    assert anvil.logger.level == anvil.logging.INFO
    assert anvil.logger.isEnabledFor(anvil.logging.INFO)
    assert not anvil.logger.isEnabledFor(anvil.logging.DEBUG)

    # Test level 2 (DEBUG)
    anvil.set_verbosity(2)
    assert anvil.logger.level == anvil.logging.DEBUG
    assert anvil.logger.isEnabledFor(anvil.logging.DEBUG)


def test_format_call_result(test_output_dir, mock_quiet_run_command, mock_run_command):
    """Test that format_call_result formats different output types correctly."""
    # Create mock ABI file
    abi_content = [
        {
            "name": "isSomething",
            "type": "function",
            "inputs": [],
            "outputs": [{"name": "result", "type": "bool"}],
        },
        {
            "name": "isSomethingElse",
            "type": "function",
            "inputs": [],
            "outputs": [{"name": "result", "type": "bool"}],
        },
        {
            "name": "getNumber",
            "type": "function",
            "inputs": [],
            "outputs": [{"name": "value", "type": "uint256"}],
        },
        {
            "name": "getAddress",
            "type": "function",
            "inputs": [],
            "outputs": [{"name": "addr", "type": "address"}],
        },
    ]
    create_mock_abi(test_output_dir, "MyContract", abi_content)

    # Set up mocks
    def mock_command(cmd):
        if "find" in cmd:
            return MagicMock(
                returncode=0, stdout=str(test_output_dir / "MyContract.json"), stderr=""
            )
        elif "jq" in cmd and "getNumber" in " ".join(cmd):
            return MagicMock(returncode=0, stdout=json.dumps(abi_content[2]), stderr="")
        elif "jq" in cmd and "isSomething" in " ".join(cmd):
            return MagicMock(returncode=0, stdout=json.dumps(abi_content[0]), stderr="")
        elif "jq" in cmd and "isSomethingElse" in " ".join(cmd):
            return MagicMock(returncode=0, stdout=json.dumps(abi_content[1]), stderr="")
        elif "jq" in cmd and "getAddress" in " ".join(cmd):
            return MagicMock(returncode=0, stdout=json.dumps(abi_content[3]), stderr="")
        else:
            return MagicMock(returncode=0, stdout="", stderr="")

    mock_quiet_run_command.side_effect = mock_command
    mock_run_command.side_effect = mock_command

    with patch("bin.anvil.run_command", mock_run_command):
        # Test integer result
        result = anvil.format_call_result(
            "0x000000000000000000000000000000000000000000000000000000000000002a",
            "MyContract.getNumber",
        )
        assert result == "42"

        # Test boolean results
        result = anvil.format_call_result("0x0", "MyContract.isSomething")
        assert result == "false"
        result = anvil.format_call_result("0x1", "MyContract.isSomethingElse")
        assert result == "true"

        # Test address result
        address = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
        result = anvil.format_call_result(address, "MyContract.getAddress")
        assert result == address
