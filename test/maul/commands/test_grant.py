import os
# Import test utilities
from test.utils.test_helpers import (setup_test_environment)
from unittest.mock import MagicMock, patch


# Import the command to test
from maul.commands.grant import GrantCommand


# Test add_arguments method
def test_add_arguments():
    parser = MagicMock()
    GrantCommand.add_arguments(parser)

    # Verify arguments were added
    parser.add_argument.assert_any_call(
        "--role", required=True, help="Role identifier/name"
    )
    parser.add_argument.assert_any_call(
        "--on", required=True, help="Contract address with role system"
    )
    parser.add_argument.assert_any_call(
        "--to", required=True, help="Address to receive the role"
    )
    parser.add_argument.assert_any_call(
        "--as", dest="as_", help="Address to impersonate when granting"
    )


# Test execute method with impersonation
def test_execute_with_impersonation():
    # Set up a complete test environment
    _test_env = setup_test_environment()

    # Apply patches - but DON'T patch send() which is what calls with_impersonation
    with patch(
        "bin.maul.utils.set_subprocess_runner", return_value=None
    ) as _mock_set_runner, patch("maul.utils.role_number_of", return_value="123"), patch(
        "maul.commands.grant.role_number_of", return_value="123"
    ), patch(
        "maul.core.eth.with_impersonation"
    ) as mock_with_impersonation, patch(
        "maul.core.eth._send", return_value=MagicMock(stdout="0xtxhash")
    ):

        # Configure mocks for context manager
        mock_context = MagicMock()
        mock_context.__enter__.return_value = (
            "0x3333444455556666777788889999000011112222"
        )
        mock_with_impersonation.return_value = mock_context

        # Create args
        args = MagicMock(
            network="mainnet",
            role="ADMIN_ROLE",
            on="contract",
            to="recipient",
            as_="impersonator",
        )

        # Execute with our patched environment
        result = GrantCommand.execute(args)

        # Verify result
        assert result["status"] == "success"
        assert result["role"] == "ADMIN_ROLE"

        # Verify the context manager was called
        mock_with_impersonation.assert_called_once()


# Test execute method with private key
def test_execute_with_private_key():
    # Create a comprehensive mock environment - fixed syntax errors
    with patch("maul.commands.grant.grant_role") as mock_grant_role, patch(
        "bin.maul.utils.run_command", return_value=MagicMock(stdout="123")
    ), patch.dict(os.environ, {"PRIVATE_KEY": "0xprivatekey"}):

        # Configure the mock to return a success result
        mock_grant_role.return_value = {"status": "success"}

        # Create args
        args = MagicMock(
            network="mainnet",
            role="ADMIN_ROLE",
            on="contract",
            to="recipient",
            as_=None,
        )

        # Execute
        result = GrantCommand.execute(args)

        # Verify grant_role was called correctly
        mock_grant_role.assert_called_once_with(
            "mainnet", "contract", "ADMIN_ROLE", "recipient", as_=None
        )

        # Verify result
        assert result["status"] == "success"
        assert result["role"] == "ADMIN_ROLE"
        assert result["contract"] == "contract"
        assert result["user"] == "recipient"
