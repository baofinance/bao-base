"""Exception classes for MAUL."""

class MaulException(Exception):
    """Base exception for all MAUL-related errors."""
    pass

class CommandError(MaulException):
    """Exception raised when a command fails to execute."""
    pass

class CommandLoadError(MaulException):
    """Exception raised when a command fails to load."""
    pass

class CommandNotFoundError(MaulException):
    """Exception raised when a command is not found."""
    pass

class ConfigurationError(MaulException):
    """Exception raised when there's an issue with configuration."""
    pass

class ConfigLoadError(MaulException):
    """Exception raised when configuration fails to load."""
    pass
