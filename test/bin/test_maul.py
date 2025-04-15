"""
Unit tests for the main maul command-line interface.
"""

import sys
from unittest.mock import MagicMock, patch

import pytest

# Import the main function from the correct location
from maul.run import main as maul_main


def test_help_info(capsys):
    """Test that maul shows help information."""
    # Capture the output
    with pytest.raises(SystemExit):
        with patch.object(sys, "argv", ["maul", "--help"]):
            maul_main()

    # Get the captured output
    captured = capsys.readouterr()

    # Check that help information is displayed
    assert "usage: maul" in captured.out or "usage: maul" in captured.err
    assert "commands" in captured.out or "commands" in captured.err


def test_version_info():
    """Test that version information is displayed."""
    with patch("bin.maul.run.create_parser") as mock_create_parser:
        # Mock the parser and args
        mock_parser = MagicMock()
        mock_parser.parse_args.return_value = MagicMock(command=None)
        mock_create_parser.return_value = mock_parser

        # Call the main function - it returns an exit code instead of raising SystemExit
        result = maul_main()

        # Verify exit code and that help was printed
        assert result == 1
        mock_parser.print_help.assert_called_once()


def test_command_not_found():
    """Test behavior when a command is not found."""
    with patch("bin.maul.run.create_parser") as mock_create_parser, patch(
        "bin.maul.run.get_command"
    ) as mock_get_command:

        # Mock parser to return args with a non-existent command
        mock_parser = MagicMock()
        mock_parser.parse_args.return_value = MagicMock(command="nonexistent")
        mock_create_parser.return_value = mock_parser

        # Mock get_command to return None (command not found)
        mock_get_command.return_value = None

        # Call the main function
        result = maul_main()

        # Verify that it returned an error code
        assert result == 1
