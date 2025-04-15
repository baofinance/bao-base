"""
Implementation of the 'send' command for MAUL CLI.

This command makes a state-changing transaction to a contract.
"""

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger
from mauled.eth.address_lookup import address_of, address_of_arguments
from mauled.eth.cast_command import run_cast_command
from mauled.eth.impersonation import with_impersonation
from mauled.eth.send_call import parse_sig

logger = get_logger()


@register_command(name="send", help_text="State-changing transaction to contract")
class SendCommand(Command):
    """Command to make a state-changing transaction to a contract."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the send command."""
        parser.add_argument("--to", required=True, help="Contract address")
        parser.add_argument(
            "--sig",
            required=True,
            help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')",
        )
        parser.add_argument("--as", dest="as_", help="Address to impersonate for the transaction")
        parser.add_argument("args", nargs="*", help="Arguments to pass to function")

    @classmethod
    def execute(cls, args):
        """Execute the send command."""
        to_address = address_of(args.network, args.to)
        to = f"{args.to} ({to_address})" if to_address != args.to else args.to

        if args.as_:
            as_address = address_of(args.network, args.as_)
            as_ = " as " + args.as_ + " (" + as_address + ")" if as_address != args.as_ else ""
        else:
            as_address = None
            as_ = ""

        # Parse the signature
        sig, param_types = parse_sig(args.network, args.sig)

        # Process arguments (resolve addresses)
        processed_args = address_of_arguments(args.network, args.args, param_types)

        logger.info(f"send to {to} with signature {sig}{as_}...")

        # Execute the command and capture result
        with_impersonation(
            args.rpc_url,
            args.as_ or address_of(args.network, "me"),
            address_of(args.network, "me"),
            lambda impersonation_args: (
                run_cast_command(
                    ["cast", "send", "--rpc-url", args.rpc_url, to_address]
                    + impersonation_args
                    + [sig]
                    + processed_args
                    + (["-" + "v" * args.v] if args.v > 0 else [])
                )
            ),
        )
