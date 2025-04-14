"""
Implementation of the 'grant' command for MAUL CLI.

This command grants a role on a contract to an address.
"""

import os

from mauled.command.base import Command, register_command
from mauled.core.logging import get_logger
from mauled.core.subprocess import run_command
from mauled.eth.roles import role_number_of

from bin.mauled.eth.address_lookup import address_of

logger = get_logger()


@register_command(name="grant", help_text="Grant a role on a contract")
class GrantCommand(Command):
    """Command to grant a role on a contract."""

    @classmethod
    def add_arguments(cls, parser):
        """Add arguments for the grant command."""
        parser.add_argument("--role", required=True, help="Role identifier/name")
        parser.add_argument(
            "--on", required=True, help="Contract address with role system"
        )
        parser.add_argument("--to", required=True, help="Address to receive the role")
        parser.add_argument(
            "--as", dest="as_", help="Address to impersonate when granting"
        )

    @classmethod
    def execute(cls, args):
        """Execute the grant command."""
        on_address = address_of(args.network, args.on)
        to_address = address_of(args.network, args.to)
        role_number = role_number_of(args.network, args.rpc_url, args.role, on_address)
        print(f"*** grant role {args.role} on {args.on} to {args.to} as {args.as_}...")

        # Use the same authentication mechanism as the 'send' command
        auth_flags = []
        if args.as_:
            # When impersonating, we need to use --unlocked
            as_address = address_of(args.network, args.as_)
            auth_flags = ["--from", as_address, "--unlocked"]
        else:
            # When not impersonating, try to use the private key from env var
            pk = os.getenv("PRIVATE_KEY")
            if pk:
                auth_flags = ["--private-key", pk]
            else:
                # If no PK available, use --unlocked with default address
                default_addr = address_of(args.network, "me")
                auth_flags = ["--from", default_addr, "--unlocked"]

        # Run the grantRoles transaction directly with authentication
        run_command(
            [
                "cast",
                "send",
                "--rpc-url",
                args.rpc_url,
                on_address,
                "grantRoles(address,uint256)",
                to_address,
                role_number,
            ]
            + auth_flags
        )
