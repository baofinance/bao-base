"""Running a command with its output copied to the console and to a log file.

Shared by the long runs (CI-long, test-long), which are left going overnight and read the next
morning: the console shows the run as it happens, and the log keeps it once the terminal is gone.
"""

import subprocess
import sys
from datetime import datetime
from pathlib import Path


def timestamped_log(name: str) -> Path:
    """Create tmp/<name>-<YYYYmmdd-HHMMSS>.log and return its path, so every run keeps its own record.

    A second run started in the same second finds the file already there and raises rather than
    writing over the first run's record.
    """
    log = Path("tmp") / f"{name}-{datetime.now():%Y%m%d-%H%M%S}.log"
    log.parent.mkdir(exist_ok=True)
    log.touch(exist_ok=False)
    return log


def announce(message: str, log: Path) -> None:
    """Print a line of the run's own narration, and append it to the log."""
    print(message, flush=True)
    with open(log, "a", encoding="utf-8") as out:
        out.write(message + "\n")


def run_logged(command: list[str], log: Path, env: dict[str, str] | None = None) -> int:
    """Run `command`, copying its stdout and stderr to the console and appending them to `log`.

    Each line is flushed as it arrives, so a run that is still going - or that died part-way - can be
    read from the log. Returns the command's exit status.
    """
    with (
        open(log, "a", encoding="utf-8") as out,
        subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
        ) as process,
    ):
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            out.write(line)
            out.flush()
        return process.wait()
