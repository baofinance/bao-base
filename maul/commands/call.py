"""Command to call contract functions."""

from bin.maul.base import Command, register_command  # Updated import path
from bin.maul.logging import get_logger

from ..core import format_call_result
from ..core.eth import call
from ..utils import address_of

logger = get_logger()


@register_command(name="call", help_text="Read-only call to contract")
class CallCommand(Command):

    @classmethod
    def add_arguments(cls, parser):
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
        # Parse the signature
        sig, param_types = cls.parse_sig(args.network, args.sig)

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
        logger.info(f"Calling {args.to} with signature {sig}{as_info}")

        # Use the core call function that handles impersonation
        result = call(args.network, args.to, sig, *processed_args, as_=args.as_)

        # Format and display the result
        if result.stdout:
            formatted_result = format_call_result(result.stdout, args.sig, args.network)
            logger.info(f"Result: {formatted_result}")
            return {"result": formatted_result}

        return {"status": "success", "no_output": True}

    @staticmethod
    def parse_sig(network, sig_input):
        """
        Parse a signature input which can be either:
        1. A full function signature like 'transfer(address,uint256)'
        2. A contract.function format like 'ERC20.transfer'

        Returns:
            tuple: (signature_string, param_types)
        """
        if "(" in sig_input:
            # Case 1: It's already a function signature
            func_name = sig_input[: sig_input.find("(")]
            param_str = sig_input[sig_input.find("(") + 1 : sig_input.find(")")]
            param_types = param_str.split(",") if param_str else []
            return sig_input, param_types
        elif "." in sig_input:
            # Case 2: It's in contract.function format
            contract, func_name = sig_input.split(".", 1)
            func_info = get_function_info(contract, func_name)
            return func_info["signature"], func_info["param_types"]
        else:
            logger.error(f"Invalid signature format '{sig_input}'")
            logger.error("Signature must be either 'function(type1,type2)' or 'Contract.function'")
            raise ValueError(f"Invalid signature format: {sig_input}")
