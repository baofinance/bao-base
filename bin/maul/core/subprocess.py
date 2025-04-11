"""Core utility functions for MAUL command-line infrastructure."""

import json
import logging
import os
import re
import subprocess
from typing import Callable, Dict, List, Optional, Union

from .logging import get_logger

logger = get_logger()

# Dependency-injectable subprocess runner for testing
_subprocess_runner = subprocess.run


def set_subprocess_runner(runner: Callable):
    """
    Set custom subprocess runner for testing or special environments.

    Args:
        runner: Function that implements subprocess.run interface
    """
    global _subprocess_runner
    old_runner = _subprocess_runner
    _subprocess_runner = runner
    return old_runner


def reset_subprocess_runner():
    """Reset subprocess runner to default implementation."""
    global _subprocess_runner
    _subprocess_runner = subprocess.run


def run_command(cmd_list, capture_output=True, check=True, **kwargs):
    """
    Run a command and return the result.

    Args:
        cmd_list: List of command arguments
        capture_output: Whether to capture stdout/stderr
        check: Whether to check the return code
        **kwargs: Additional arguments to pass to subprocess.run

    Returns:
        CompletedProcess object
    """
    cmd_str = " ".join(cmd_list)
    logger.debug(f"Running command: {cmd_str}")

    # Only print command at INFO level and above if we're executing cast/anvil operations
    if cmd_list and cmd_list[0] in ["cast", "anvil"]:
        logger.info(f">>> {cmd_str}")

    result = _subprocess_runner(
        cmd_list, capture_output=capture_output, check=check, text=True, **kwargs
    )

    # Log stdout/stderr at debug level
    if result.stdout and logger.isEnabledFor(logging.DEBUG):
        logger.debug(f"Command stdout: {result.stdout.strip()}")

    if result.stderr and logger.isEnabledFor(logging.DEBUG):
        logger.debug(f"Command stderr: {result.stderr.strip()}")

    # Log return code at debug level
    logger.debug(f"Command returned: {result.returncode}")

    return result


def quiet_run_command(command):
    """
    Run command and return result without checking exit code.

    Args:
        command: Command list to execute

    Returns:
        CompletedProcess object
    """
    cmd_str = " ".join(command)
    logger.debug(f"Running command (quiet): {cmd_str}")

    # Only print command at INFO level and above if we're executing cast/anvil operations
    if command[0] in ["cast", "anvil"]:
        logger.info(f">>> {cmd_str}")

    result = _subprocess_runner(command, capture_output=True, text=True, check=False)

    # Log stdout/stderr at different levels based on verbosity
    if result.stdout:
        logger.debug(f"Command stdout: {result.stdout.strip()}")

    if result.stderr:
        logger.debug(f"Command stderr: {result.stderr.strip()}")

    # Log return code at DEBUG level
    logger.debug(f"Command returned: {result.returncode}")

    return result


# Standard test result class for mocking command execution
class CommandResult:
    """Result of a command execution for testing."""

    def __init__(self, stdout="", stderr="", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode

    def __repr__(self):
        return f"CommandResult(returncode={self.returncode})"




# Add to exports
__all__ = [
    "run_command",
    "quiet_run_command",
    "get_function_info",
    "format_call_result",
    "CommandResult",
    "parse_sig",
    "decode_custom_error",
    "search_abi_for_error",
    "set_subprocess_runner",
    "reset_subprocess_runner",
    "ether_to_wei",
    "wei_to_ether",
    "wei_to_hex",
]
