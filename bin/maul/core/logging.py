"""Logging configuration for MAUL."""

import logging
import os
import sys

# Define custom logging levels that match bash script behavior
# Standard levels are: DEBUG=10, INFO=20, WARNING=30, ERROR=40, CRITICAL=50
# Add intermediate INFO levels
logging.INFO1 = 19  # Just below standard INFO
logging.INFO2 = 18
logging.INFO3 = 17
logging.INFO4 = 16  # Just above DEBUG

# Register the new level names
logging.addLevelName(logging.INFO1, "INFO1")
logging.addLevelName(logging.INFO2, "INFO2")
logging.addLevelName(logging.INFO3, "INFO3")
logging.addLevelName(logging.INFO4, "INFO4")

# Special level for quiet mode - using a very high level to ensure nothing is displayed
logging.QUIET = 100
logging.addLevelName(logging.QUIET, "QUIET")


# Add logger methods for the new levels
def info1(self, message, *args, **kwargs):
    """Log message at INFO1 level (for -v verbosity)."""
    if self.isEnabledFor(logging.INFO1):
        self._log(logging.INFO1, message, args, **kwargs)


def info2(self, message, *args, **kwargs):
    """Log message at INFO2 level (for -vv verbosity)."""
    if self.isEnabledFor(logging.INFO2):
        self._log(logging.INFO2, message, args, **kwargs)


def info3(self, message, *args, **kwargs):
    """Log message at INFO3 level (for -vvv verbosity)."""
    if self.isEnabledFor(logging.INFO3):
        self._log(logging.INFO3, message, args, **kwargs)


def info4(self, message, *args, **kwargs):
    """Log message at INFO4 level (for -vvvv verbosity)."""
    if self.isEnabledFor(logging.INFO4):
        self._log(logging.INFO4, message, args, **kwargs)


# Add the methods to the Logger class
logging.Logger.info1 = info1
logging.Logger.info2 = info2
logging.Logger.info3 = info3
logging.Logger.info4 = info4


def configure_logging(verbosity, quiet):
    """Configure the logging system based on verbosity level."""

    # Use BAO_BASE_VERBOSITY directly if verbosity not specified
    if verbosity is None:
        verbosity = int(os.environ.get("BAO_BASE_VERBOSITY", "0"))
    verbosity = int(verbosity)

    # Create/get the logger
    _logger = logging.getLogger("maul")

    # Check if DEBUG contains 'q' for quiet mode (similar to -q flag)
    debug_exists = "DEBUG" in os.environ
    debug_enabled = False

    if debug_exists:
        quiet = False
        # Check if verbosity is being modified via DEBUG var
        for part in os.environ.get("DEBUG", "").split(","):
            if part.startswith("-v"):
                # Count the number of v's to determine verbosity
                v_count = part.count("v")
                if v_count > 0:
                    verbosity = v_count  # environment overrides what is passed in
            elif part.startswith("-q"):
                quiet = True
            elif part == "maul":
                debug_enabled = True

    # Set logging level based on verbosity and quiet flags
    if quiet:
        # Quiet mode - use the special QUIET level to suppress all output
        _logger.setLevel(logging.ERROR)  # Use ERROR instead of QUIET
    else:
        # Direct mapping from verbosity to log level
        if verbosity == 0:
            _logger.setLevel(logging.INFO)  # Default is now INFO, not WARNING
        elif verbosity == 1:
            _logger.setLevel(logging.INFO1)  # -v
        elif verbosity == 2:
            _logger.setLevel(logging.INFO2)  # -vv
        elif verbosity == 3:
            _logger.setLevel(logging.INFO3)  # -vvv
        elif verbosity == 4:
            _logger.setLevel(logging.INFO4)  # -vvvv
        else:  # 5 or higher (super verbose)
            raise ValueError("Verbosity level too high. Use -v, -vv, -vvv, or -vvvv.")

        # Override with DEBUG if maul is in DEBUG environment variable
        if debug_enabled:
            _logger.setLevel(logging.DEBUG)

    # Add handlers if they don't exist
    if not _logger.handlers:
        # Console handler
        handler = logging.StreamHandler(sys.stderr)

        # Use more detailed format for all levels if debug is enabled
        if debug_exists:

            class RelativePathFormatter(logging.Formatter):
                def format(self, record):
                    # Store original pathname before modifying
                    if hasattr(record, "pathname"):
                        # Convert to path relative to current directory
                        record.rel_pathname = os.path.relpath(
                            record.pathname, os.getcwd()
                        )
                    return super().format(record)

            formatter = RelativePathFormatter(
                "%(levelname)s: %(rel_pathname)s:%(lineno)d: %(message)s"
            )
        else:
            formatter = logging.Formatter("%(levelname)s: %(message)s")

        handler.setFormatter(formatter)
        _logger.addHandler(handler)


def get_logger():
    """Get the MAUL logger."""
    return logging.getLogger("maul")
