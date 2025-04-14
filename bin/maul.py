#! /usr/bin/env python3
# -*- coding: utf-8 -*-
# This script is a command-line utility for interacting with Ethereum smart contracts with an emphasis on Minter contracts

import argparse
import json
import logging
import os
import re
import signal
import sys
import threading
import time

import commentjson
from dotenv import load_dotenv
# Change relative import to absolute import since PYTHONPATH includes bin/ directory
from mauled.core.logging import configure_logging, get_logger
from mauled.eth.address import address_of, bcinfo
from mauled.eth.grab import TokenAcquisitionMethod, grab, grab_erc20, grab_upto
from mauled.eth.impersonation import enable_impersonation, with_impersonation

from bin.mauled.core.subprocess import run_command, run_command_quiet

load_dotenv()  # Load .env file once

deploy_log = "./log/deploy-local.log"
ABI_DIR = os.getenv("ABI_DIR", "./out")

logger = get_logger()


# Use imported run_command_quiet as quiet_run_command for compatibility
quiet_run_command = run_command_quiet


def decode_custom_error(error_data, contract_name=None, sig_input=None):
    """
    Attempt to decode a custom error returned by a contract

    Args:
        error_data: The error data string (e.g. '0xc6052bd8')
        contract_name: Optional contract name to look for the error in
        sig_input: The signature input that was used (for contract name extraction)

    Returns:
        tuple: (decoded_error, raw_data)
            decoded_error - Human-readable error message
            raw_data - Original error data
    """
    if not error_data.startswith("0x"):
        return f"Error: {error_data}", error_data

    error_id = error_data[:10]  # Error selector is first 4 bytes (8 hex chars + '0x')
    logger.debug(f"Looking up error selector: {error_id}")

    # Extract contract name from the signature input if available
    if sig_input and "." in sig_input and not contract_name:
        contract_name = sig_input.split(".", 1)[0]
        logger.debug(f"Extracted contract name {contract_name} from signature")

    # Try to get error signature using cast 4byte-decode first
    logger.debug(f"Trying to decode error selector {error_id}")
    result = quiet_run_command(["cast", "4byte-decode", error_id])
    if result.returncode == 0 and result.stdout.strip():
        logger.debug(f"Found error via 4byte-decode: {result.stdout.strip()}")
        return f"Error: {result.stdout.strip()}", error_data

    # Look for error definitions in contract ABIs
    contract_names = []

    # First, try the specifically mentioned contract
    if contract_name:
        contract_names.append(contract_name)

    # If we have a target contract address, find all ABIs and check them
    if len(error_id) == 10:  # Valid selector
        # First search in the specific contract's ABI
        if contract_name:
            # Find the contract ABI file
            find_result = quiet_run_command(
                ["find", ABI_DIR, "-name", f"{contract_name}.json", "-print", "-quit"]
            )

            if find_result.returncode == 0 and find_result.stdout.strip():
                found_error = search_abi_for_error(
                    find_result.stdout.strip(), error_id, error_data
                )
                if found_error:
                    return found_error

        # Then search all contract ABIs
        logger.debug("Searching all contract ABIs for the error selector")
        find_all_result = quiet_run_command(
            ["find", ABI_DIR, "-name", "*.json", "-type", "f"]
        )

        if find_all_result.returncode == 0 and find_all_result.stdout.strip():
            for abi_path in find_all_result.stdout.strip().split("\n"):
                # Skip already checked contract
                if contract_name and abi_path.endswith(f"/{contract_name}.json"):
                    continue

                found_error = search_abi_for_error(abi_path, error_id, error_data)
                if found_error:
                    return found_error

    # If all attempts fail, return the original error data
    return f"Custom error: {error_id}", error_data


def search_abi_for_error(abi_path, error_id, error_data):
    """
    Search an ABI file for an error definition matching the given selector

    Args:
        abi_path: Path to the ABI JSON file
        error_id: Error selector (0x + 8 hex digits)
        error_data: Full error data for parameter decoding

    Returns:
        tuple or None: (decoded_error, raw_data) if found, None otherwise
    """
    logger.debug(f"Checking ABI file: {abi_path}")

    # Extract the contract name from the path for better error messages
    contract_name = os.path.basename(abi_path).split(".")[0]

    # Extract errors using type filter
    error_result = quiet_run_command(
        ["jq", "-c", '.abi[] | select(.type == "error")', abi_path]
    )

    if error_result.returncode == 0 and error_result.stdout.strip():
        logger.debug(f"Found errors in {contract_name}")

        # Process each error definition
        for error_json in error_result.stdout.strip().split("\n"):
            try:
                error = json.loads(error_json)
                name = error.get("name", "")
                inputs = error.get("inputs", [])

                if name:
                    # Create the error signature for calldata decoding
                    param_types = [
                        input_param.get("type", "") for input_param in inputs
                    ]
                    sig = f"{name}({','.join(param_types)})"

                    # Calculate the selector to check for a match
                    selector_result = quiet_run_command(["cast", "keccak", sig])
                    if selector_result.returncode == 0:
                        # Get just the first 10 characters (0x + 8 for 4 bytes)
                        selector = selector_result.stdout.strip()[:10]
                        logger.debug(f"Error {name} has selector {selector}")

                        if selector == error_id:
                            logger.debug(
                                f"Found matching error in {contract_name}: {sig}"
                            )

                            # Try to decode the full error data with parameters
                            decoded_params = ""

                            if len(error_data) > 10 and inputs:  # Contains parameters
                                calldata_result = quiet_run_command(
                                    ["cast", "calldata", sig, error_data]
                                )
                                if (
                                    calldata_result.returncode == 0
                                    and calldata_result.stdout.strip()
                                ):
                                    # Format parameter names if available
                                    param_info = []
                                    decoded_values = (
                                        calldata_result.stdout.strip().split("\n")
                                    )

                                    for i, param in enumerate(inputs):
                                        if i < len(decoded_values):
                                            param_name = param.get("name", f"param{i}")
                                            param_value = decoded_values[i].strip()
                                            param_info.append(
                                                f"{param_name}={param_value}"
                                            )

                                    decoded_params = ", ".join(param_info)

                            # Build full error description
                            error_description = f"Error: {name}"
                            if decoded_params:
                                error_description += f"({decoded_params})"

                            # Include the contract name for context
                            error_description += f" [from {contract_name}]"

                            # Return both the decoded error and the raw data
                            return error_description, error_data
            except Exception as e:
                logger.debug(f"Error processing error definition: {e}")

    return None


# Custom error handler for Ethereum-specific commands
def ethereum_error_handler(result):
    """Custom error handler for Ethereum commands that can decode custom errors"""
    print(f"*** Command failed: {' '.join(result.args)}")

    # Extract command info for better error context
    cmd_type = result.args[0] if result.args else "Unknown"
    sig_input = None
    if (
        len(result.args) > 3
        and cmd_type in ["cast"]
        and result.args[1] in ["call", "send"]
    ):
        # For call/send, the signature is the 3rd arg
        sig_input = result.args[3] if len(result.args) > 3 else None

    if result.stderr:
        error_msg = result.stderr.strip()

        # Look for custom error pattern in the error message
        custom_error_match = None
        if "custom error" in error_msg:
            import re

            # Extract the custom error data
            custom_error_match = re.search(
                r'custom error ([^,\s]+)(?:, data: "([^"]+)")?', error_msg
            )

        if custom_error_match:
            error_selector = custom_error_match.group(1)
            error_data = (
                custom_error_match.group(2)
                if custom_error_match.group(2)
                else error_selector
            )

            # Try to decode the error with context from the command
            decoded_error, raw_data = decode_custom_error(
                error_data, sig_input=sig_input
            )

            # Print both decoded error and raw data
            print(f"*** {decoded_error}")
            print(f"*** Raw error data: {raw_data}")
        else:
            print(f"*** Error: {error_msg}")

    if result.stdout:
        print(f"*** Output: {result.stdout.strip()}")

    print(f"*** Exit code: {result.returncode}")
    sys.exit(result.returncode)


def role_number_of(network, rpc_url, role, on):
    if role.startswith("0x") or role.isdigit():
        return role
    on_address = address_of(network, on)
    result = run_command(
        ["cast", "call", "--rpc-url", rpc_url, on_address, f"{role}()(uint256)"]
    )
    output = result.stdout.strip().split()
    if not output:
        raise ValueError(f"Role {role} not found on {on}")
    return output[0]


def get_function_type_string(param):
    """
    Get the full type string for a parameter, properly formatting complex types

    Args:
        param: Parameter object from ABI

    Returns:
        str: Properly formatted type string
    """
    type_str = param.get("type", "")

    # Handle tuple types - need to recursively process components
    if type_str == "tuple":
        components = param.get("components", [])
        component_types = [get_function_type_string(comp) for comp in components]
        return f"({','.join(component_types)})"

    return type_str


def get_function_info(contract, func_name):
    """
    Get comprehensive information about a function from its ABI

    Args:
        contract: Contract name to look up
        func_name: Function name to look up

    Returns:
        dict: Dictionary containing function information:
            'signature': Full function signature (e.g. 'transfer(address,uint256)')
            'param_types': List of parameter types
            'inputs': List of input parameter details (name, type, etc.)
            'outputs': List of output parameter details
            'abi_path': Path to the contract ABI file
    """
    # Find the contract ABI file
    result = run_command(
        ["find", ABI_DIR, "-name", f"{contract}.json", "-print", "-quit"]
    )
    abi_path = result.stdout.strip()
    if not abi_path:
        print(f"error: Contract ABI file not found for {contract}")
        sys.exit(1)

    # Get detailed function information including inputs and outputs
    result = run_command(
        [
            "jq",
            f'.abi[] | select(.name == "{func_name}" and .type == "function")',
            abi_path,
        ]
    )

    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: Function {func_name} not found in contract {contract}")
        sys.exit(1)

    try:
        func_data = json.loads(result.stdout.strip())

        # Extract parameter types for the signature - properly handle complex types
        param_types = [
            get_function_type_string(input_param)
            for input_param in func_data.get("inputs", [])
        ]
        param_str = ",".join(param_types)

        return {
            "signature": f"{func_name}({param_str})",
            "param_types": param_types,
            "inputs": func_data.get("inputs", []),
            "outputs": func_data.get("outputs", []),
            "abi_path": abi_path,
        }
    except json.JSONDecodeError:
        print(f"error: Invalid JSON in ABI for {contract}.{func_name}")
        sys.exit(1)


def get_event_info(contract, event_name):
    """
    Get comprehensive information about an event from its ABI

    Args:
        contract: Contract name to look up
        event_name: Event name to look up

    Returns:
        dict: Dictionary containing event information:
            'signature': Full event signature (e.g. 'Transfer(address,address,uint256)')
            'param_types': List of parameter types
            'inputs': List of input parameter details (name, type, indexed, etc.)
            'abi_path': Path to the contract ABI file
    """
    # Find the contract ABI file
    result = run_command(
        ["find", ABI_DIR, "-name", f"{contract}.json", "-print", "-quit"]
    )
    abi_path = result.stdout.strip()
    if not abi_path:
        print(f"error: Contract ABI file not found for {contract}")
        sys.exit(1)

    # Get detailed event information including inputs
    result = run_command(
        [
            "jq",
            f'.abi[] | select(.name == "{event_name}" and .type == "event")',
            abi_path,
        ]
    )

    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: Event {event_name} not found in contract {contract}")
        sys.exit(1)

    try:
        event_data = json.loads(result.stdout.strip())

        # Extract parameter types for the signature - properly handle complex types
        param_types = [
            get_function_type_string(input_param)
            for input_param in event_data.get("inputs", [])
        ]
        param_str = ",".join(param_types)

        return {
            "signature": f"{event_name}({param_str})",
            "param_types": param_types,
            "inputs": event_data.get("inputs", []),
            "abi_path": abi_path,
        }
    except json.JSONDecodeError:
        print(f"error: Invalid JSON in ABI for {contract}.{event_name}")
        sys.exit(1)


def lookup_env(env_name):
    value = os.getenv(env_name, "")
    if not value and os.path.isfile(".env"):
        with open(".env") as f:
            for line in f:
                if line.startswith(env_name + "="):
                    value = line.strip().split("=", 1)[1]
                    break
    return value


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
        print(f"*** Error: Invalid signature format '{sig_input}'")
        print(
            "*** Signature must be either 'function(type1,type2)' or 'Contract.function'"
        )
        sys.exit(1)


def start(network, chain_id, port, rpc_url):
    # Store the anvil process so we can terminate it properly
    anvil_process = None

    def wait_for_anvil():
        while quiet_run_command(["nc", "-z", "localhost", str(port)]).returncode != 0:
            time.sleep(1)
        print("*** allowing baomultisig to be impersonated...")
        # Also use RPC URL with port specified to ensure commands target the correct anvil instance
        enable_impersonation(
            network, rpc_url, "baomultisig", on_error=ethereum_error_handler
        )
        grab_upto(network, rpc_url, "baomultisig", "1")

    def signal_handler(sig, frame):
        print(f"\n*** Received signal {sig}, terminating anvil process...")
        if anvil_process:
            # Use os.kill instead of process.terminate() for more forceful termination
            try:
                os.kill(anvil_process.pid, signal.SIGTERM)
                time.sleep(0.5)  # Give it a brief moment to terminate gracefully

                # If still running, force kill
                if anvil_process and anvil_process.poll() is None:
                    os.kill(anvil_process.pid, signal.SIGKILL)
                    print("*** Forcefully killed anvil process")
            except OSError as e:
                print(f"Error terminating process: {e}")

        # Exit immediately without calling any other handlers
        os._exit(0)

    # Register the signal handlers for multiple signals
    original_sigint_handler = signal.signal(signal.SIGINT, signal_handler)
    original_sigterm_handler = signal.signal(signal.SIGTERM, signal_handler)

    try:
        anvil_thread = threading.Thread(target=wait_for_anvil)
        anvil_thread.daemon = (
            True  # Make thread a daemon so it exits when main thread exits
        )
        anvil_thread.start()

        # Use subprocess.Popen instead of run_command for direct process control
        cmd = ["anvil", "-f", network]
        # Add optional parameters
        if chain_id:
            cmd.extend(["--chain-id", str(chain_id)])
        if port:
            cmd.extend(["--port", str(port)])

        logger.info(f">>> {' '.join(cmd)}")
        anvil_process = subprocess.Popen(cmd)

        # Use polling instead of wait() to avoid blocking indefinitely
        # This allows the script to respond to signals from the test framework
        while anvil_process.poll() is None:
            time.sleep(0.1)

        # If we get here, anvil exited on its own
        exit_code = anvil_process.returncode
        print(f"*** Anvil process exited with code: {exit_code}")
        return exit_code
    finally:
        # Restore original signal handlers
        signal.signal(signal.SIGINT, original_sigint_handler)
        signal.signal(signal.SIGTERM, original_sigterm_handler)

        # Make absolutely sure the process is terminated
        if anvil_process and anvil_process.poll() is None:
            try:
                os.kill(anvil_process.pid, signal.SIGKILL)
                print("*** Killed anvil process during cleanup")
            except OSError:
                pass


def format_call_result(stdout, sig_input, network=None):
    """
    Format call result based on the output content and expected return type from ABI

    Args:
        stdout: The stdout from the cast call command
        sig_input: The signature input (e.g. 'ERC20.balanceOf')
        network: The network being used (for context)
    """
    result = stdout.strip()

    # If it's an empty result
    if not result:
        return "No result"

    # Try to get ABI information about return type
    output_type = None
    if sig_input and "." in sig_input:
        try:
            contract, func_name = sig_input.split(".", 1)
            func_info = get_function_info(contract, func_name)
            if func_info and func_info["outputs"] and len(func_info["outputs"]) > 0:
                output_type = func_info["outputs"][0].get("type")
        except Exception as e:
            logger.debug(f"Error getting output type from ABI: {e}")

    # Handle specific output types
    if output_type:
        logger.debug(f"Function returns type: {output_type}")

        # Integer types (uint*, int*)
        if output_type.startswith(("uint", "int")):
            if result.startswith("0x"):
                try:
                    decimal_value = int(result, 16)
                    return f"{decimal_value}"  # Just show decimal for ints
                except ValueError:
                    pass

        # Boolean type
        elif output_type == "bool":
            if result == "0x0" or result == "0":
                return "false"
            elif result == "0x1" or result == "1":
                return "true"

        # Address type
        elif output_type == "address":
            # For addresses, always return the hex format
            if result.startswith("0x"):
                return result
            else:
                # If it's somehow not in hex format already, try to convert it
                try:
                    # Try to convert decimal to hex if needed
                    decimal_value = int(result)
                    return f"0x{decimal_value:040x}"
                except ValueError:
                    pass
                return result

        # Bytes and string types
        elif output_type.startswith(("bytes", "string")):
            # Try to decode if it looks like hex
            if result.startswith("0x"):
                try:
                    # Try to decode as string if it's UTF-8 encodable
                    bytes_value = bytes.fromhex(result[2:])
                    string_value = bytes_value.decode("utf-8", errors="replace")
                    if all(c.isprintable() or c.isspace() for c in string_value):
                        return f'{result} (decoded: "{string_value}")'
                except (ValueError, UnicodeDecodeError):
                    pass

    # For array or structured output (multi-line)
    if "\n" in result:
        return f"\n{result}"

    # Default case
    return result


def main():
    # Create the top-level parser with better help
    parser = argparse.ArgumentParser(
        description="""maul script for deoloying on, and interacting with, blockchains or anvil.

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

    parser.add_argument(
        "-v", action="count", default=0, help="Increase verbosity level"
    )
    parser.add_argument(
        "-q", action="store_true", help="Stop all output (apart from errors)"
    )

    # Create subparsers for commands
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")
    # subparsers.required = False  # Make subcommand optional, default to "start"

    # Start command
    start_parser = subparsers.add_parser("start", help="Start anvil instance")
    start_parser.add_argument(
        "--chain-id", type=int, help="Specify chain ID for the anvil instance"
    )
    start_parser.add_argument(
        "--port", type=int, help="Port number to use the anvil instance listens on"
    )
    # Mark start command as local-only
    start_parser.set_defaults(local_only=True)

    # Grant command
    grant_parser = subparsers.add_parser("grant", help="Grant a role on a contract")
    grant_parser.add_argument("--role", required=True, help="Role identifier/name")
    grant_parser.add_argument(
        "--on", required=True, help="Contract address with role system"
    )
    grant_parser.add_argument("--to", required=True, help="Address to receive the role")
    grant_parser.add_argument(
        "--as", dest="as_", help="Address to impersonate when granting"
    )

    # Call command
    call_parser = subparsers.add_parser("call", help="Read-only call to contract")
    call_parser.add_argument("--to", required=True, help="Contract address")
    call_parser.add_argument(
        "--sig",
        required=True,
        help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')",
    )
    call_parser.add_argument(
        "--as", dest="as_", help="Address to impersonate for the call"
    )
    call_parser.add_argument(
        "args", nargs=argparse.REMAINDER, help="Arguments to pass to function"
    )

    # Send command
    send_parser = subparsers.add_parser(
        "send", help="State-changing transaction to contract"
    )
    send_parser.add_argument("--to", required=True, help="Contract address")
    send_parser.add_argument(
        "--sig",
        required=True,
        help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')",
    )
    send_parser.add_argument(
        "--as", dest="as_", help="Address to impersonate for the transaction"
    )
    send_parser.add_argument(
        "args", nargs=argparse.REMAINDER, help="Arguments to pass to function"
    )

    # Sig command
    sig_parser = subparsers.add_parser(
        "sig", help="Look up function or event signature"
    )
    sig_parser.add_argument(
        "signature",
        help="Either a signature (e.g., 'transfer(address,uint256)') or Contract.name (e.g., 'ERC20.transfer')",
    )

    # Add mutually exclusive group for function/event flags
    sig_type_group = sig_parser.add_mutually_exclusive_group()
    sig_type_group.add_argument(
        "--function",
        action="store_true",
        default=True,
        help="Look up a function signature (default)",
    )
    sig_type_group.add_argument(
        "--event", action="store_true", default=False, help="Look up an event signature"
    )

    # Steal command and aliases
    steal_aliases = [
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
    ]
    steal_parser = subparsers.add_parser(
        "steal", help="Add tokens to an address", aliases=steal_aliases
    )
    steal_parser.add_argument(
        "--erc20", help="ERC20 token address or name (if omitted, steals ETH)"
    )
    steal_parser.add_argument("--to", required=True, help="Recipient address")
    steal_parser.add_argument(
        "--amount", required=True, help="Amount of tokens to transfer"
    )
    steal_parser.add_argument(
        "--method",
        choices=["mint", "whale", "storage", "admin", "logs", "all"],
        default="all",
        help="Method to use for ERC20 token acquisition (default: all)",
    )

    # address command
    adddress_of_parser = subparsers.add_parser("address", help="lookup known address")
    adddress_of_parser.add_argument("--of", help="Specify name of the address")

    # Parse arguments
    args = parser.parse_args()

    # Validate local-only commands
    if hasattr(args, "command") and args.command:
        # Validate local-only commands
        local_only_commands = ["start"]  # Commands that only work in local mode

        # Check for local-only command with --no-local flag
        if args.command in local_only_commands and not args.use_local:
            print(
                f"Error: The '{args.command}' command can only be used in local mode (without --no-local)."
            )
            sys.exit(1)

        # Validate options that require local mode
        if not args.use_local:
            # Check for --as flag which requires impersonation (local-only)
            if hasattr(args, "as_") and args.as_:
                print(
                    f"Error: The '--as' option can only be used in local mode (without --no-local)."
                )
                sys.exit(1)

            # Check for steal command with --erc20 flag
            if (
                args.command in ["steal"] + steal_aliases
                and hasattr(args, "erc20")
                and args.erc20
            ):
                print(
                    f"Error: The '{args.command} --erc20' command can only be used in local mode (without --no-local)."
                )
                sys.exit(1)

    configure_logging(args.v, args.q)
    # Convert count to Foundry's verbosity flag format (e.g., -vvv)
    verbosity = "-" + "v" * args.v if args.v > 0 else ""

    # Extract rpc_url and rpc_port from local/network arguments
    if args.use_local:
        # --local was specified
        rpc_url = f"http://localhost:{args.local_port or 8545}"
    else:
        # --no-local was specified
        rpc_url = args.network
        if args.network.startswith("http"):
            # If it's a URL, use it directly
            logger.error("--chain cannot be an actual url: {args.network}")
            sys.exit(1)

    logger.info(f"Processing command: {args.command}")

    # Execute commands
    if args.command in ["steal"] + steal_aliases:
        if args.erc20:
            print(
                f"*** transfer {args.to} {args.amount} ERC20 {args.erc20} (method: {args.method})"
            )
            success = grab_erc20(
                args.network,
                rpc_url,
                args.to,
                args.amount,
                args.erc20,
                method=args.method,  # Pass the method parameter
            )
            if not success:
                print(f"*** Failed to acquire tokens using method: {args.method}")
                sys.exit(1)
        else:
            print(f"*** transfer {args.to} {args.amount} ETH")
            grab(args.network, rpc_url, args.to, args.amount)

    elif args.command == "grant":
        on_address = address_of(args.network, args.on)
        to_address = address_of(args.network, args.to)
        role_number = role_number_of(args.network, args.role, on_address)
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
                on_address,
                "grantRoles(address,uint256)",
                to_address,
                role_number,
            ]
            + auth_flags
        )

    elif args.command in ["call", "send"]:
        to_address = address_of(args.network, args.to)
        to = f"{args.to} ({to_address})" if to_address != args.to else args.to
        if args.as_:
            as_address = address_of(args.network, args.as_)
            as_ = (
                " as " + args.as_ + " (" + as_address + ")"
                if as_address != args.as_
                else ""
            )
        else:
            as_address = None
            as_ = ""
        # Parse the signature
        sig, param_types = parse_sig(args.network, args.sig)

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

        print(f"*** {args.command} to {to} with signature {sig}{as_}...")
        if processed_args != args.args:
            logger.debug(f"Converted arguments: {args.args} -> {processed_args}")

        # Prepare auth flags for send command
        auth_flags = []
        if args.command == "send":
            # For 'send', we need to specify how the transaction will be signed
            if as_address:
                # When impersonating, we need to use --unlocked
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

        # Execute the command and capture result
        result = with_impersonation(
            args.network,
            rpc_url,
            args.as_,
            lambda as_address: (
                run_command(
                    ["cast", args.command, "--rpc-url", rpc_url, to_address, sig]
                    + processed_args
                    + (auth_flags if args.command == "send" else [])
                    + ([verbosity] if verbosity else [])
                )
            ),
            on_error=ethereum_error_handler,
        )

        # For 'call' operations, show the result
        if args.command == "call" and result.stdout:
            formatted_result = format_call_result(result.stdout, args.sig, args.network)
            print(f"Result: {formatted_result}")

    elif args.command == "start":
        start(args.network, args.chain_id, args.port, rpc_url)

    elif args.command == "sig":
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
    elif args.command == "address":
        address = address_of(args.network, args.of)
        print(f"{args.of} address is {address}")
    else:
        if args.command:
            logger.error(f"Unknown command '{args.command}'")
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
