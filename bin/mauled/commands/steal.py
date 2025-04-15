"""
Implementation of the 'steal' command for MAUL CLI.

This command adds ETH or ERC20 tokens to an address.
"""

import sys
from decimal import Decimal
from typing import List

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger
from mauled.eth import grab, grab_erc20

logger = get_logger()


@register_command(
    name="steal",
    help_text="Add tokens to an address",
    aliases=[
        "pinch",
        "nick",
        "grab",
        "pilfer",
        "embezzle",
        "rob",
        "swipe",
        "thieve",
        "filch",
        "purloin",
        "lift",
        "pillage",
        "plunder",
        "loot",
        "snatch",
    ],
)
class StealCommand(Command):
    """Command to add tokens to an address."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the steal command."""
        parser.add_argument("--erc20", help="ERC20 token address or name (if omitted, steals ETH)")
        parser.add_argument("--to", required=True, help="Recipient address")
        parser.add_argument("--amount", required=True, type=Decimal, help="Amount of tokens to transfer")
        aquisition_methods = ["mint", "whale", "storage", "admin", "logs"]
        parser.add_argument(
            "--method",
            nargs="+",  # Accept multiple methods as an array
            choices=aquisition_methods,
            default=[],
            help=f"Methods to use for ERC20 token acquisition, in order of preference (default: all). Valid methods: {', '.join(aquisition_methods)}",
        )

    @classmethod
    def verify_local_mode(cls, args):
        """
        Verify that we're in local mode when using ERC20 tokens.

        Args:
            args: Command-line arguments

        Raises:
            SystemExit: If trying to use --erc20 in non-local mode
        """
        # Check for steal command with --erc20 flag in non-local mode
        if hasattr(args, "erc20") and args.erc20 and not args.use_local:
            print(f"Error: The '{args.command} --erc20' command can only be used in local mode (without --no-local).")
            sys.exit(1)

    @classmethod
    def execute(cls, args):
        """Execute the steal command."""
        # Verify local mode constraints first
        cls.verify_local_mode(args)

        if args.erc20:
            logger.info(f"steal for {args.to} {args.amount} ERC20 {args.erc20} (method: {args.method})")
            success = grab_erc20(
                args.network,
                args.rpc_url,
                args.to,
                args.amount,
                args.erc20,
                methods=args.method,  # Pass the methods array
            )
            if not success:
                logger.error(f"Failed to acquire tokens using method: {args.method}")
                sys.exit(1)
        else:
            print(f"steal for {args.to} {args.amount} ETH")
            grab(args.network, args.rpc_url, args.to, args.amount)
