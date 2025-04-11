import os
import signal
import socket
import subprocess
import time

import pytest


@pytest.fixture(scope="session")
def anvil_process():
    """Start anvil in the background for tests that need a blockchain."""
    # Check if anvil is already running
    if _is_port_in_use(8545):
        # Anvil is already running, no need to start it
        yield None
        return

    # Start anvil
    process = subprocess.Popen(
        ["anvil", "-f", "mainnet"], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )

    # Wait for anvil to start
    for _ in range(30):
        if _is_port_in_use(8545):
            break
        time.sleep(0.5)
    else:
        process.terminate()
        process.wait()
        raise RuntimeError("Anvil failed to start")

    # Yield the process for tests to use
    yield process

    # Clean up
    process.terminate()
    process.wait(timeout=5)

    # Force kill if still running
    if process.poll() is None:
        os.kill(process.pid, signal.SIGKILL)


def _is_port_in_use(port):
    """Check if a port is in use."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("localhost", port)) == 0
