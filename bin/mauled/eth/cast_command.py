import re
import subprocess
import sys
from typing import List

from mauled.core.subprocess import quiet_run_command, run_command
from mauled.eth.error_handler import ethereum_error_handler  # Updated import


def run_cast_command(command: List[str]) -> subprocess.CompletedProcess:
    result = quiet_run_command(command)
    if result.returncode != 0:
        # Use custom error handler for Ethereum commands
        ethereum_error_handler(result)
    return result


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
