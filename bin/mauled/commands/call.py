"""
Implementation of the 'call' command for MAUL CLI.

This command makes a read-only call to a contract.
"""

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger
from mauled.eth.address_lookup import address_of, address_of_arguments
from mauled.eth.cast_command import run_cast_command
from mauled.eth.send_call import format_call_result, parse_sig

logger = get_logger()


@register_command(name="call", help_text="Read-only call to contract")
class CallCommand(Command):
    """Command to make a read-only call to a contract."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the call command."""
        parser.add_argument("--to", required=True, help="Contract address")
        parser.add_argument(
            "--sig",
            required=True,
            help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')",
        )
        parser.add_argument("--as", dest="as_", help="Address to impersonate for the call")
        parser.add_argument("args", nargs="*", help="Arguments to pass to function")

    @classmethod
    def execute(cls, args):
        """Execute the call command."""
        # Parse the signature
        sig, param_types = parse_sig(args.network, args.sig)

        # Process arguments (resolve addresses)
        processed_args = address_of_arguments(args.network, args.args, param_types)

        # Execute the command and capture result
        # result = with_impersonation(
        #     args.rpc_url,
        #     args.as_,
        #     address_of(args.network, "me"),
        #     lambda impersonation_args: (
        #         run_command(
        #             [
        #                 "cast",
        #                 "call",
        #                 "--rpc-url",
        #                 args.rpc_url,
        #                 address_of(args.network, args.to),
        #             ]
        #             + impersonation_args
        #             + [sig]
        #             + processed_args
        #             + (["-" + "v" * args.v] if args.v > 0 else [])
        #         )
        #     ),
        #     on_error=ethereum_error_handler,
        # )

        result = run_cast_command(
            [
                "cast",
                "call",
                "--rpc-url",
                args.rpc_url,
                address_of(args.network, args.to),
            ]
            + [sig]
            + processed_args
            + (["-" + "v" * args.v] if args.v > 0 else [])
        )
        # Format and display the result
        if result.stdout:
            formatted_result = format_call_result(result.stdout, args.sig, args.network)
            print(f"Result: {formatted_result}")

        return result
