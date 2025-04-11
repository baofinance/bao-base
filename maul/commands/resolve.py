"""Command to resolve addresses."""

from bin.maul.logging import get_logger
from bin.maul.base import Command, register_command
from maul.resolution import address_of

logger = get_logger()


@register_command(name="resolve", help_text="Resolve a name to an address")
class ResolveCommand(Command):
    """Command to resolve contract or wallet names to addresses."""

    name = "resolve"
    help = "Resolve a name to an address"

    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument("name", help="Name to resolve")
        parser.add_argument(
            "--network", "-n", default="mainnet", help="Network to use for resolution"
        )

    @classmethod
    def execute(cls, args):
        address = address_of(args.network, args.name)
        if address:
            print(address)
            return {"status": "success", "address": address}
        else:
            logger.error(f"Failed to resolve name: {args.name}")
            return {"status": "error", "message": f"Could not resolve {args.name}"}
