"""Command to decode error data."""

from bin.maul.base import Command, register_command  # Fixed import path
from bin.maul.logging import get_logger
from bin.maul.utils import decode_custom_error

logger = get_logger()


@register_command(name="decode", help_text="Decode custom error data")
class DecodeCommand(Command):
    """Command to decode custom error data."""

    name = "decode"
    help = "Decode custom error data"

    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument("error_data", help="Error data to decode")
        parser.add_argument("contract", nargs="?", help="Contract name for context")

    @classmethod
    def execute(cls, args):
        decoded, raw = decode_custom_error(args.error_data, args.contract)
        print(decoded)
