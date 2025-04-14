"""
Implementation of the 'address' command for MAUL CLI.

This command looks up addresses by name.
"""

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger

from bin.mauled.eth.address_lookup import address_of

logger = get_logger()


@register_command(name="address", help_text="Look up known address")
class AddressCommand(Command):
    """Command to look up addresses by name."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the address command."""
        parser.add_argument("--of", help="Specify name of the address")

    @classmethod
    def execute(cls, args):
        """Execute the address command."""
        address = address_of(args.network, args.of)
        print(f"{args.of} address is {address}")
        return address
