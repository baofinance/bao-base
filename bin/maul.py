#! /usr/bin/env python3
# -*- coding: utf-8 -*-
# This script is a command-line utility for interacting with Ethereum smart contracts with an emphasis on Minter contracts

import argparse
import os
import sys

# Import all commands to ensure they're registered
from dotenv import load_dotenv
from mauled.command.base import get_all_commands, get_command, import_commands_from_dir
from mauled.core.logging import configure_logging, get_logger

# Change relative import to absolute import since PYTHONPATH includes bin/ directory

logger = get_logger()
configure_logging()

load_dotenv()  # Load .env file once

deploy_log = "./log/deploy-local.log"
ABI_DIR = os.getenv("ABI_DIR", "./out")


# Import all command modules
import_commands_from_dir(commands_path="bin/mauled/commands")


def lookup_env(env_name):
    """Look up an environment variable, checking .env file if needed"""
    value = os.getenv(env_name, "")
    if not value and os.path.isfile(".env"):
        with open(".env") as f:
            for line in f:
                if line.startswith(env_name + "="):
                    value = line.strip().split("=", 1)[1]
                    break
    return value


def main():
    """Main entry point for the MAUL CLI tool"""
    # Create the top-level parser with descriptive help
    parser = argparse.ArgumentParser(
        description="""maul script for deploying on, and interacting with, blockchains or anvil.

A maul is a large hammer typically used against an anvil to forge something useful.
This maul has many uses, like it's namesake, from cracking a nut to knocking something into shape
to bludeoning some <insert your pet hate here>. It can also make a mess so be wary of what you ask of it.
It is particularly useful for reading files with addresses in it for ease of use.""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  maul.py start -f mainnet                             # Start anvil forked from mainnet
  maul.py start -f mainnet --chain-id 1                # Start anvil with specific chain ID
  maul.py start -f mainnet --port 8546                 # Start anvil on a custom port
  maul.py steal --to me --amount 100                   # Add 100 ETH to your account
  maul.py steal --to me --amount 1 --erc20 wsteth      # Add 1 wstETH to your account
  maul.py grant --role MINTER_ROLE --on token --to me  # Grant role on contract
  maul.py sig ERC20.transfer                           # Show function signature
        """,
    )

    # Create a mutually exclusive group for local/no-local options
    local_group = parser.add_mutually_exclusive_group()
    local_group.add_argument(
        "--no-local",
        dest="use_local",
        action="store_false",
        help="Do not use local anvil instance (use live chain instead)",
    )
    local_group.add_argument(
        "--local",
        "--port",
        dest="local_port",
        nargs="?",
        const=True,  # When --local is specified without a value
        type=int,  # When --local is specified with a value, treat as int
        help="Use local anvil instance, optionally specifying port number (default: 8545)",
    )

    parser.add_argument(
        "--chain",
        "-f",
        dest="network",
        default="mainnet",
        help="Chain to: fork from, to connect to, or to lookup addresses, etc.",
    )

    parser.add_argument("-v", action="count", default=0, help="Increase verbosity level")
    parser.add_argument("-q", action="store_true", help="Stop all output (apart from errors)")

    # Create subparsers for commands
    subparsers = parser.add_subparsers(dest="command", title="commands", help="Available commands")

    # Register all commands from the registry
    all_commands = get_all_commands()
    for name, cmd_class in all_commands.items():
        # Skip aliases - they'll be registered when we process the main command
        if hasattr(cmd_class, "aliases") and name in cmd_class.aliases:
            continue

        # Create subparser for this command
        cmd_parser = subparsers.add_parser(name, help=cmd_class.help)

        # Let the command add its arguments
        cmd_class.add_arguments(cmd_parser)

        # Handle command aliases if this command has any
        if hasattr(cmd_class, "aliases"):
            for alias in cmd_class.aliases:
                alias_parser = subparsers.add_parser(alias, help=f"Alias for '{name}'")
                cmd_class.add_arguments(alias_parser)

    # Parse arguments
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    configure_logging(args.v, args.q)

    # Extract rpc_url from local/network arguments
    if args.use_local:
        # --local was specified
        args.rpc_url = f"http://localhost:{args.local_port or 8545}"
    else:
        # --no-local was specified
        if args.network.startswith("http"):
            logger.error(f"--chain cannot be an actual url: {args.network}")
            sys.exit(1)
        args.rpc_url = args.network

    logger.info(f"Processing command: {args.command}")
    logger.info1(f"- args: {vars(args)}")

    # Validate local-only commands
    local_only_commands = ["start"]  # Commands that only work in local mode

    # Check for local-only command with --no-local flag
    if args.command in local_only_commands and not args.use_local:
        print(f"Error: The '{args.command}' command can only be used in local mode (without --no-local).")
        sys.exit(1)

    # Validate options that require local mode
    if not args.use_local:
        # Check for --as flag which requires impersonation (local-only)
        if hasattr(args, "as_") and args.as_:
            print(f"Error: The '--as' option can only be used in local mode (without --no-local).")
            sys.exit(1)

        # The check for steal command with --erc20 has been moved to StealCommand.verify_local_mode

    # Get the command from registry
    cmd_class = get_command(args.command)

    if cmd_class:
        # Execute the command
        try:
            result = cmd_class.execute(args)
            return result
        except Exception as e:
            logger.error(f"Error executing command: {e}", exc_info=True)
            sys.exit(1)
    else:
        logger.error(f"Unknown command '{args.command}'")
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
