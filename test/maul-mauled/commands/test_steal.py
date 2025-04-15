from unittest.mock import MagicMock, patch

# Import directly from implementation module
from mauled.commands.steal import StealCommand


# Test add_arguments method
def test_add_arguments():
    parser = MagicMock()
    StealCommand.add_arguments(parser)

    # Verify arguments were added
    parser.add_argument.assert_any_call("--erc20", help="ERC20 token address or name (if omitted, steals ETH)")
    parser.add_argument.assert_any_call("--to", required=True, help="Recipient address")
    parser.add_argument.assert_any_call("--amount", required=True, help="Amount of tokens to transfer")


# Test execute method for ETH
def test_execute_eth():
    # NOTE: We must patch where the function is imported, not where it's defined
    # StealCommand imports grab from maul.commands.steal.grab, so we patch that path
    with patch("maul.commands.steal.grab") as mock_grab, patch.object(StealCommand, "logger") as mock_logger:

        # Configure mocks
        mock_grab.return_value = "10.0"

        # Create args
        args = MagicMock(
            network="mainnet",
            erc20=None,
            to="0x1234567890123456789012345678901234567890",
            amount="10",
        )

        # Execute
        result = StealCommand.execute(args)

        # Verify logger calls
        mock_logger.info.assert_called_once_with("Transferring 10 ETH to 0x1234567890123456789012345678901234567890")

        # Verify grab call
        mock_grab.assert_called_once_with("mainnet", "0x1234567890123456789012345678901234567890", "10")

        # Verify result
        assert result["status"] == "success"
        assert result["recipient"] == "0x1234567890123456789012345678901234567890"
        assert result["amount"] == "10"
        assert result["balance"] == "10.0"


# Test execute method for ERC20
def test_execute_erc20():
    # NOTE: We must patch where the function is imported, not where it's defined
    # StealCommand imports grab_erc20 from maul.commands.steal.grab_erc20, so we patch that path
    with patch("maul.commands.steal.grab_erc20") as mock_grab_erc20, patch.object(
        StealCommand, "logger"
    ) as mock_logger:

        # Configure mocks
        mock_grab_erc20.return_value = {
            "status": "success",
            "requested": "5",
            "acquired": "5.0",
            "token": "0xabcdef1234567890abcdef1234567890abcdef12",
        }

        # Create args
        args = MagicMock(
            network="mainnet",
            erc20="0xabcdef1234567890abcdef1234567890abcdef12",
            to="0x1234567890123456789012345678901234567890",
            amount="5",
        )

        # Execute
        result = StealCommand.execute(args)

        # Verify logger calls
        mock_logger.info.assert_called_once_with(
            "Transferring 5 ERC20 0xabcdef1234567890abcdef1234567890abcdef12 to 0x1234567890123456789012345678901234567890"
        )

        # Verify grab_erc20 call
        mock_grab_erc20.assert_called_once_with(
            "mainnet",
            "0x1234567890123456789012345678901234567890",
            "5",
            "0xabcdef1234567890abcdef1234567890abcdef12",
        )

        # Verify result
        assert result["status"] == "success"
        assert result["recipient"] == "0x1234567890123456789012345678901234567890"
        assert result["amount"] == "5"
        assert "token" in result
