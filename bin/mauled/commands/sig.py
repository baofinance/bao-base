"""
Implementation of the 'sig' command for MAUL CLI.

This command looks up function or event signatures.
"""

import sys

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger

from bin.maul import get_event_info, get_function_info

logger = get_logger()


@register_command(name="sig", help_text="Look up function or event signature")
class SigCommand(Command):
    """Command to look up function or event signatures."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the sig command."""
        parser.add_argument(
            "signature",
            help="Either a signature (e.g., 'transfer(address,uint256)') or Contract.name (e.g., 'ERC20.transfer')",
        )

        # Add mutually exclusive group for function/event flags
        sig_type_group = parser.add_mutually_exclusive_group()
        sig_type_group.add_argument(
            "--function",
            action="store_true",
            default=True,
            help="Look up a function signature (default)",
        )
        sig_type_group.add_argument(
            "--event",
            action="store_true",
            default=False,
            help="Look up an event signature",
        )

    @classmethod
    def execute(cls, args):
        """Execute the sig command."""
        # Parse the signature format using the format Contract.name
        if "." in args.signature:
            contract, name = args.signature.split(".", 1)

            # Choose function or event lookup based on flags
            if args.event:
                info = get_event_info(contract, name)
                type_label = "event"
            else:
                info = get_function_info(contract, name)
                type_label = "function"

            output = f"{type_label} signature for {contract}.{name} is \"{info['signature']}\""

            # Display input parameters if available
            if info["inputs"]:
                output += "\nInput Parameters:"
                for i, param in enumerate(info["inputs"]):
                    name = param.get("name", "unnamed")
                    type_name = param.get("type", "")
                    indexed = (
                        " (indexed)" if param.get("indexed") and args.event else ""
                    )
                    output += f"\n  {i+1}. {name}: {type_name}{indexed}"

            # Display return parameters if available (only for functions)
            if not args.event and "outputs" in info and info["outputs"]:
                output += "\nReturn Values:"
                for i, param in enumerate(info["outputs"]):
                    name = param.get("name", f"return_{i}")
                    type_name = param.get("type", "")
                    output += f"\n  {i+1}. {name}: {type_name}"

            print(output)
        else:
            logger.error(
                f"Signature must be in the form Contract.name: {args.signature}"
            )
            sys.exit(1)
