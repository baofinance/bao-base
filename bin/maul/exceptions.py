"""Exceptions for the maul command system."""


class MaulError(Exception):
    """Base class for all maul-specific exceptions."""

    pass


class CommandLoadError(MaulError):
    """Error loading a command module."""

    pass


class CommandNotFoundError(MaulError):
    """Command not found in registry."""

    pass


class ConfigLoadError(MaulError):
    """Error loading configuration."""

    pass
