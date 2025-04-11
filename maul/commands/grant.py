"""Command to grant roles."""

import os
from bin.maul.base import Command, register_command  # Updated import path
from ..utils import run_command, address_of, role_number_of
from ..core.eth import grant_role
from bin.maul.logging import get_logger

logger = get_logger()

@register_command(name="grant", help_text="Grant a role to a user")
class GrantCommand(Command):

    @classmethod
    def add_arguments(cls, parser):
        # Update to match test expectations
        parser.add_argument(
            "--role", required=True,
            help="Role identifier/name"
        )
        parser.add_argument(
            "--to", required=True,
            help="Address to receive the role"
        )
        parser.add_argument(
            "--on", required=True,
            help="Contract address with role system"
        )
        parser.add_argument(
            "--as", dest="as_",
            help="Address to impersonate when granting"
        )

    @classmethod
    def execute(cls, args):
        # Use the higher-level grant_role function that handles impersonation
        result = grant_role(
            args.network,
            args.on,
            args.role,
            args.to,
            as_=args.as_
        )

        # Return standardized result
        return {
            "status": "success",
            "role": args.role,
            "user": args.to,
            "contract": args.on
        }