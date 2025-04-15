import os
import subprocess
from unittest.mock import MagicMock, patch

import pytest

# Import directly from implementation module
from mauled.commands.start import StartCommand


# Test add_arguments method
def test_add_arguments():
    parser = MagicMock()
    StartCommand.add_arguments(parser)

    # Verify arguments were added
    parser.add_argument.assert_any_call("--chain-id", type=int, help="Specify chain ID for the anvil instance")
    parser.add_argument.assert_any_call("--interactive", "-i", action="store_true", help="Start in interactive mode")


# Test execute method (updated for simplified implementation)
def test_execute_basic():
    """Test the basic execution flow of the StartCommand with simplified implementation."""
    # Mock the necessary components
    with patch.object(StartCommand, "logger") as mock_logger, patch("subprocess.Popen") as mock_popen, patch(
        "time.sleep"
    ) as _mock_sleep, patch(  # Correctly define _mock_sleep as a patch
        "maul.commands.start.quiet_run_command"
    ) as mock_quiet_run, patch(
        "maul.commands.start.run_command"
    ) as mock_run_command, patch(
        "maul.commands.start.bcinfo",
        return_value="0x8765fda26e2f80c98fe65a2f9ee192ca1e03d75d",
    ), patch(
        "maul.commands.start.grab", return_value="1.0"
    ), patch(
        "os.kill"
    ) as _mock_kill:  # Rename mock_kill to _mock_kill

        # Configure process mock to return immediately
        mock_popen_instance = MagicMock()
        mock_popen_instance.wait.return_value = 0
        mock_popen_instance.poll.side_effect = [None, 0]
        mock_popen.return_value = mock_popen_instance

        # Configure mock_quiet_run to simulate port open after first attempt
        mock_quiet_run.return_value = MagicMock(returncode=0)

        # Create args
        args = MagicMock(network="mainnet", chain_id=None, port=8545)

        # Execute
        result = StartCommand.execute(args)

        # Verify the process was started with correct arguments
        mock_popen.assert_called_once_with(["anvil", "-f", "mainnet", "--port", "8545"])

        # Verify port check happened
        mock_quiet_run.assert_called_with(["nc", "-z", "localhost", "8545"])

        # Verify RPC calls for impersonation and funding
        assert mock_run_command.call_count >= 1
        mock_run_command.assert_any_call(
            [
                "cast",
                "rpc",
                "--rpc-url",
                "http://localhost:8545",
                "anvil_impersonateAccount",
                "0x8765fda26e2f80c98fe65a2f9ee192ca1e03d75d",
            ]
        )

        # Verify the grab call
        assert "multisig" in str(mock_logger.info.call_args_list)

        # Verify process wait was called
        mock_popen_instance.wait.assert_called_once()

        # Verify result
        assert result["status"] == "completed"
        assert result["network"] == "mainnet"


# Integration test - requires actual anvil binary
@pytest.mark.integration
def test_start_command_integration(monkeypatch):
    import signal
    import time

    # Only run if specifically enabled
    if not os.environ.get("RUN_INTEGRATION_TESTS"):
        pytest.skip("Integration tests disabled")

    # Make the process manageable
    with patch.object(StartCommand, "logger"), patch("signal.signal"):

        # Create a mock Popen that we can control
        real_popen = subprocess.Popen

        def mock_popen(cmd, *args, **kwargs):
            process = real_popen(cmd, *args, **kwargs)
            return process

        with patch("subprocess.Popen", side_effect=mock_popen):
            # Create args
            args = MagicMock(network="mainnet", chain_id=None)

            # Start a thread to kill the process after a delay
            def delayed_kill():
                time.sleep(1)  # Give it time to start
                os.kill(os.getpid(), signal.SIGINT)

            import threading

            killer = threading.Thread(target=delayed_kill)
            killer.daemon = True
            killer.start()

            # Execute should return without error when killed
            try:
                result = StartCommand.execute(args)
                assert result["status"] == "completed"
                assert result["network"] == "mainnet"
            except SystemExit:
                pass  # Expected due to signal
