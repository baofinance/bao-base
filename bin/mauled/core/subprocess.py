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


def quiet_run_command(command: List[str]) -> subprocess.CompletedProcess:
    """
    Run command and return result without checking exit code.
    Args:
        command: List of command and arguments to execute
    Returns:
        CompletedProcess: Result of the subprocess execution
    """
    cmd_str = " ".join(command)
    logger.info(f"$ {cmd_str}")

    result = subprocess.run(command, capture_output=True, text=True)

    # Log stdout/stderr at different levels based on verbosity
    if result.stdout:
        logger.info1(f"Ccommand details:\n  Command: {cmd_str}\n  Exit code: {result.returncode}")
        logger.info2(f"Command stdout: {result.stdout.strip()}")

    if result.stderr:
        # Always show stderr at regular TRACE level
        logger.error(f"Command stderr: {result.stderr.strip()}")

    return result


def run_command(
    command: List[str],
) -> subprocess.CompletedProcess:
    """
    Run command, exitting on error
    Args:
        command: List of command and arguments to execute
    Returns:
        CompletedProcess: Result of the subprocess execution
    Raises:
        SystemExit: If command fails and exit_on_error is True
    """
    result = quiet_run_command(command)

    # TODO: add command exception
    # Check for failure
    if result.returncode != 0:
        raise Exception(f"Command failed with exit code {result.returncode}")
    return result
