"""
Utilities for subprocess execution with appropriate logging and error handling.

This module provides functions for running external commands with consistent
logging and customizable error handling.
"""

import subprocess
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple

from mauled.core.logging import get_logger

logger = get_logger()


def run_command_quiet(command: List[str]) -> subprocess.CompletedProcess:
    """
    Run command and return result without checking exit code or raising exceptions.

    Args:
        command: List of command and arguments to execute

    Returns:
        CompletedProcess: Result of the subprocess execution
    """
    cmd_str = " ".join(command)
    logger.debug(f"Running command: {cmd_str}")

    # Only print command at INFO level and above if we're executing cast/anvil operations
    if command and command[0] in ["cast", "anvil"]:
        logger.info(f">>> {cmd_str}")

    result = subprocess.run(command, capture_output=True, text=True)

    # Log stdout/stderr at different levels based on verbosity
    if result.stdout:
        logger.info1(f"Command stdout: {result.stdout.strip()}")
        logger.info2(
            f"Full command details:\n  Command: {cmd_str}\n  Exit code: {result.returncode}\n  Full stdout: \n{result.stdout}"
        )

    if result.stderr:
        # Always show stderr at regular TRACE level
        logger.info1(f"Command stderr: {result.stderr.strip()}")

    # Log return code at DEBUG level
    logger.debug(f"Command returned: {result.returncode}")

    return result


def run_command(
    command: List[str],
    on_error: Optional[Callable[[subprocess.CompletedProcess], Any]] = None,
    exit_on_error: bool = True,
) -> subprocess.CompletedProcess:
    """
    Run command and handle errors based on provided callback or default behavior.

    Args:
        command: List of command and arguments to execute
        on_error: Optional function to call when command fails (gets CompletedProcess as arg)
        exit_on_error: Whether to exit the program on error (default: True)

    Returns:
        CompletedProcess: Result of the subprocess execution

    Raises:
        SystemExit: If command fails and exit_on_error is True
    """
    result = run_command_quiet(command)

    # Check for failure
    if result.returncode != 0:
        # Call custom error handler if provided
        if on_error:
            return on_error(result)

        # Default error handling
        print(f"*** Command failed: {' '.join(command)}")

        if result.stderr:
            print(f"*** Error: {result.stderr.strip()}")

        if result.stdout:
            print(f"*** Output: {result.stdout.strip()}")

        print(f"*** Exit code: {result.returncode}")

        # Exit if specified
        if exit_on_error:
            sys.exit(result.returncode)

    return result
