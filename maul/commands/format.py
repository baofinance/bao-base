"""Command to format call results."""

from bin.maul.logging import get_logger
from bin.maul.utils import format_call_result
from bin.maul.base import Command, register_command

logger = get_logger()

@register_command(name="format", help_text="Format call result based on function signature")
class FormatCommand(Command):
    """Command to format call results based on function signature."""

    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument("result", help="Result to format")
        parser.add_argument("signature", nargs="?", help="Function signature for context")
        parser.add_argument("--network", "-n", default="mainnet", help="Network context")

    @classmethod
    def execute(cls, args):
        formatted = format_call_result(args.result, args.signature, args.network)
        print(formatted)
        return {"status": "success", "formatted": formatted}
