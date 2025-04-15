import re
import subprocess
import sys
from typing import List

from bin.mauled.core.subprocess import quiet_run_command, run_command
from bin.mauled.eth.error import decode_custom_error


def run_cast_command(command: List[str]) -> subprocess.CompletedProcess:
    result = quiet_run_command(command)
    if result.returncode != 0:
        # Use custom error handler for Ethereum commands
        ethereum_error_handler(result)
    return result


def ethereum_error_handler(result):
    """
    Custom error handler for Ethereum commands that can decode custom errors.

    This handler attempts to decode custom error data returned by Ethereum contracts.

    Args:
        result: Command execution result containing stdout, stderr, and args
    """
    print(f"*** Command failed: {' '.join(result.args)}")

    # Extract command info for better error context
    cmd_type = result.args[0] if result.args else "Unknown"
    sig_input = None
    if len(result.args) > 3 and cmd_type in ["cast"] and result.args[1] in ["call", "send"]:
        # For call/send, the signature is the 3rd arg
        sig_input = result.args[3] if len(result.args) > 3 else None

    if result.stderr:
        error_msg = result.stderr.strip()

        # Look for custom error pattern in the error message
        custom_error_match = None
        if "custom error" in error_msg:
            # Extract the custom error data
            custom_error_match = re.search(r'custom error ([^,\s]+)(?:, data: "([^"]+)")?', error_msg)

        if custom_error_match:
            error_selector = custom_error_match.group(1)
            error_data = custom_error_match.group(2) if custom_error_match.group(2) else error_selector

            # Try to decode the error with context from the command
            decoded_error, raw_data = decode_custom_error(error_data, sig_input=sig_input)

            # Print both decoded error and raw data
            print(f"*** {decoded_error}")
            print(f"*** Raw error data: {raw_data}")
        else:
            print(f"*** Error: {error_msg}")

    if result.stdout:
        print(f"*** Output: {result.stdout.strip()}")

    print(f"*** Exit code: {result.returncode}")
    sys.exit(result.returncode)


def run_cast_balance(rpc_url: str, wallet_address: str) -> int:
    return int(run_cast_command(["cast", "balance", "--rpc-url", rpc_url, wallet_address]).stdout.strip().split()[0])


def run_cast_latest_block(rpc_url: str) -> int:
    return int(run_command(["cast", "block", "--rpc-url", rpc_url, "latest", "-f", "number"]).stdout.strip())


def run_cast_balanceOf(rpc_url: str, token_address: str, wallet_address: str) -> int:
    return int(
        run_cast_command(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc_url,
                token_address,
                "balanceOf(address)(uint256)",
                wallet_address,
            ]
        )
        .stdout.strip()
        .split()[0]
    )
