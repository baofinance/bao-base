"""Command to steal tokens from other addresses."""

from bin.maul.base import Command, register_command  # Updated import path
from bin.maul.logging import get_logger
from ..core.eth import grab, grab_erc20  # Explicitly import grab functions

# Get the logger for the decorator registration
logger = get_logger()

@register_command(name="steal", help_text="Add tokens to an address")
class StealCommand(Command):

    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument(
            "--erc20",
            help="ERC20 token address or name (if omitted, steals ETH)"
        )
        parser.add_argument(
            "--to", required=True,
            help="Recipient address"
        )
        parser.add_argument(
            "--amount", required=True,
            help="Amount of tokens to transfer"
        )

    @classmethod
    def execute(cls, args):
        if args.erc20:
            cls.logger.info(f"Transferring {args.amount} ERC20 {args.erc20} to {args.to}")
            result = grab_erc20(args.network, args.to, args.amount, args.erc20)
            return {"status": "success", "recipient": args.to, "amount": args.amount, **result}
        else:
            cls.logger.info(f"Transferring {args.amount} ETH to {args.to}")
            eth_balance = grab(args.network, args.to, args.amount)
            return {"status": "success", "recipient": args.to, "amount": args.amount, "balance": eth_balance}