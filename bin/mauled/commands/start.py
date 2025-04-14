"""
Implementation of the 'start' command for MAUL CLI.

This command starts an Anvil instance forked from a specified network.
"""

import os
import signal
import subprocess
import sys
import threading
import time

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger
from mauled.core.subprocess import quiet_run_command
from mauled.eth.error import ethereum_error_handler
from mauled.eth.grab import grab_upto
from mauled.eth.impersonation import enable_impersonation

from bin.mauled.eth.address_lookup import bcinfo

logger = get_logger()


@register_command(name="start", help_text="Start anvil instance")
class StartCommand(Command):
    """Command to start an Anvil instance."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the start command."""
        parser.add_argument(
            "--chain-id", type=int, help="Specify chain ID for the anvil instance"
        )
        parser.add_argument(
            "--port", type=int, help="Port number to use the anvil instance listens on"
        )
        # Mark start command as local-only
        parser.set_defaults(local_only=True)

    @classmethod
    def execute(cls, args):
        """Execute the start command."""
        # Store the anvil process so we can terminate it properly
        anvil_process = None

        def wait_for_anvil():
            port = args.port or 8545
            while (
                quiet_run_command(["nc", "-z", "localhost", str(port)]).returncode != 0
            ):
                time.sleep(1)
            logger.info(f"anvil startup: allowing baomultisig to be impersonated...")
            # Also use RPC URL with port specified to ensure commands target the correct anvil instance
            enable_impersonation(
                args.network,
                args.rpc_url,
                "baomultisig",
                on_error=ethereum_error_handler,
            )
            logger.info(
                f"anvil startup: impersonation enabled for baomultisig on {args.network} ({args.rpc_url})"
            )
            grab_upto(args.network, args.rpc_url, "baomultisig", "1")

        def signal_handler(sig, frame):
            print(f"\n*** Received signal {sig}, terminating anvil process...")
            if anvil_process:
                # Use os.kill instead of process.terminate() for more forceful termination
                try:
                    os.kill(anvil_process.pid, signal.SIGTERM)
                    time.sleep(0.5)  # Give it a brief moment to terminate gracefully

                    # If still running, force kill
                    if anvil_process and anvil_process.poll() is None:
                        os.kill(anvil_process.pid, signal.SIGKILL)
                        print("*** Forcefully killed anvil process")
                except OSError as e:
                    print(f"Error terminating process: {e}")

            # Exit immediately without calling any other handlers
            os._exit(0)

        # Register the signal handlers for multiple signals
        original_sigint_handler = signal.signal(signal.SIGINT, signal_handler)
        original_sigterm_handler = signal.signal(signal.SIGTERM, signal_handler)

        try:
            anvil_thread = threading.Thread(target=wait_for_anvil)
            anvil_thread.daemon = (
                True  # Make thread a daemon so it exits when main thread exits
            )
            anvil_thread.start()

            # Use subprocess.Popen instead of run_command for direct process control
            cmd = ["anvil", "-f", args.network]
            # Add optional parameters
            if args.chain_id:
                cmd.extend(["--chain-id", str(args.chain_id)])
            if args.port:
                cmd.extend(["--port", str(args.port)])

            logger.info(f"{' '.join(cmd)}")
            anvil_process = subprocess.Popen(cmd)

            # Use polling instead of wait() to avoid blocking indefinitely
            # This allows the script to respond to signals from the test framework
            while anvil_process.poll() is None:
                time.sleep(0.1)

            # If we get here, anvil exited on its own
            exit_code = anvil_process.returncode
            print(f"*** Anvil process exited with code: {exit_code}")
            return exit_code
        finally:
            # Restore original signal handlers
            signal.signal(signal.SIGINT, original_sigint_handler)
            signal.signal(signal.SIGTERM, original_sigterm_handler)

            # Make absolutely sure the process is terminated
            if anvil_process and anvil_process.poll() is None:
                try:
                    os.kill(anvil_process.pid, signal.SIGKILL)
                    print("*** Killed anvil process during cleanup")
                except OSError:
                    pass
