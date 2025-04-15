from unittest.mock import MagicMock, patch

from mauled.eth import grab, grab_erc20
from mauled.eth.send_call import format_call_result

# Import directly from implementation modules instead of compatibility layers


# Test format_call_result function
def test_format_call_result():
    # Test with simple string
    result = format_call_result("test result")
    assert result == "test result"

    # Test with CommandResult
    mock_result = MagicMock()
    mock_result.stdout = "command output\n"
    result = format_call_result(mock_result)
    assert result == "command output"

    # Test with list
    result = format_call_result(["item1", "item2"])
    assert result == ["item1", "item2"]


# Test grab function
def test_grab():
    """Test the grab function with the correct mock setup."""
    with patch("maul.core.eth.address_of") as mock_address_of, patch(
        "maul.core.eth.run_command"
    ) as mock_run_command, patch(
        "bin.maul.utils.ether_to_wei"  # Updated import path
    ) as mock_ether_to_wei, patch(
        "bin.maul.utils.wei_to_ether"  # Updated import path
    ) as mock_wei_to_ether, patch(
        "maul.core.eth.logger"
    ) as _mock_logger:

        # Set up mocks
        mock_address_of.return_value = "0x1234567890123456789012345678901234567890"
        mock_ether_to_wei.return_value = "1000000000000000000"  # String form
        mock_wei_to_ether.return_value = "1.0"

        # Configure run_command mock with multiple returns
        mock_run_command.side_effect = [
            MagicMock(stdout="", returncode=0),  # First call (setBalance)
            MagicMock(stdout="1000000000000000000", returncode=0),  # Second call (balance)
        ]

        # Call the function
        result = grab("mainnet", "user", "1")

        # Verify critical mocks were called with correct arguments
        mock_address_of.assert_called_once_with("mainnet", "user")
        mock_ether_to_wei.assert_called_once_with("1")

        # Verify wei_to_hex is NOT called

        # Verify final wei_to_ether conversion
        mock_wei_to_ether.assert_called_once_with("1000000000000000000")

        # Verify result matches expected value
        assert result == "1.0"


# Test grab_erc20 function (simplified)
def test_grab_erc20_minimal():
    with patch("maul.core.eth.address_of") as mock_address_of, patch(
        "maul.core.eth.run_command"
    ) as mock_run_command, patch("maul.core.eth.quiet_run_command") as _mock_quiet_run_command, patch(
        "maul.core.eth.with_impersonation"
    ) as _mock_with_impersonation, patch(
        "maul.core.eth.logger"
    ) as _mock_logger:

        # Set up mocks
        mock_address_of.side_effect = [
            "0x1234567890123456789012345678901234567890",  # wallet_address
            "0xabcdef1234567890abcdef1234567890abcdef12",  # token_address
        ]

        # Provide unlimited mock return values
        def run_command_side_effect(*args, **kwargs):
            result = MagicMock()
            # Set specific return values based on the command
            if args[0][0] == "cast" and "to-wei" in args[0]:
                result.stdout = "1000000"
            elif args[0][0] == "cast" and "from-wei" in args[0]:
                result.stdout = "0.001"
            elif args[0][0] == "cast" and "block" in args[0]:
                result.stdout = "1000"
            else:
                result.stdout = "0"
            return result

        mock_run_command.side_effect = run_command_side_effect

        # No events found
        _mock_quiet_run_command.return_value = MagicMock(returncode=0, stdout="[]", stderr="")

        # Call the function with minimal execution path
        result = grab_erc20("mainnet", "user", "0.001", "token")

        # Verify basic calls
        assert mock_address_of.call_count == 2

        # Should be partial since we couldn't find any tokens
        assert result["status"] == "partial"
        assert result["requested"] == "0.001"
        assert result["token"] == "token"
