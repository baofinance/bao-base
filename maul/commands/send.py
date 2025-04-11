"""Command to send transactions."""

import os
from bin.maul.base import Command, register_command  # Updated import path
from bin.maul.logging import get_logger
from ..utils import address_of
from ..core.eth import send

logger = get_logger()

@register_command(name="send", help_text="State-changing transaction to contract")
class SendCommand(Command):

    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument(
            "--to", required=True,
            help="Contract address"
        )
        parser.add_argument(
            "--sig", required=True,
            help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')"
        )
        parser.add_argument(
            "--as", dest="as_",
            help="Address to impersonate for the transaction"
        )
        parser.add_argument(
            "args", nargs="*",
            help="Arguments to pass to function"
        )

    @classmethod
    def execute(cls, args):
        # Parse the signature
        sig, param_types = CallCommand.parse_sig(args.network, args.sig)

        # Apply address_of to any argument that corresponds to an address type
        processed_args = []
        for i, arg in enumerate(args.args):
            # Check if this parameter is an address type
            is_address = i < len(param_types) and "address" in param_types[i]

            if is_address:
                # Convert the argument to an address
                processed_args.append(address_of(args.network, arg))
            else:
                processed_args.append(arg)

        # Log what we're doing
        to_address = address_of(args.network, args.to)
        as_info = f" as {args.as_}" if args.as_ else ""
        logger.info(f"Sending transaction to {args.to} with signature {sig}{as_info}")

        # Use the core send function that handles impersonation
        result = send(
            args.network,
            args.to,
            sig,
            *processed_args,
            as_=args.as_
        )

        # Show transaction hash
        tx_hash = result.stdout.strip() if result.stdout else "Unknown"
        return {"status": "success", "transaction": tx_hash}
