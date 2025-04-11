"""Signature utility command."""

from bin.maul.base import Command, register_command  # Updated import path
from bin.maul.logging import get_logger
from bin.maul.utils import parse_sig

# Get the logger from our dedicated module
logger = get_logger()


@register_command(name="sig", help_text="Look up function signature")
class SigCommand(Command):

    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument(
            "signature",
            help="Function signature (e.g., 'ERC20.transfer' or 'transfer(address,uint256)')",
        )

    @classmethod
    def execute(cls, args):
        # Log at debug level that we're executing the command
        logger.debug(f"Executing sig command with args: {args.signature}")

        # Parse the signature using the utility function
        sig_info = parse_sig(args.signature)

        # Build output string and result data structure
        if "contract" in sig_info and sig_info["contract"]:
            output = f"Signature for {sig_info['contract']}.{sig_info['function']} is \"{sig_info['signature']}\""
        else:
            output = f"Signature: {sig_info['signature']}"

        # Display input parameters if available
        if sig_info["inputs"]:
            output += "\nInput Parameters:"
            for i, param in enumerate(sig_info["inputs"]):
                name = param.get("name", f"param{i}")
                type_name = param["type"]
                output += f"\n  {i+1}. {name}: {type_name}"

        # Display return parameters if available
        if "outputs" in sig_info and sig_info["outputs"]:
            output += "\nReturn Values:"
            for i, param in enumerate(sig_info["outputs"]):
                name = param.get("name", f"return_{i}")
                type_name = param["type"]
                output += f"\n  {i+1}. {name}: {type_name}"

        # Print to stdout - this is what users will see and tests should verify
        print(output)

        # Return raw data for programmatic use (if needed)
        return sig_info
