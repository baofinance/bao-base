#! /usr/bin/env python3
# -*- coding: utf-8 -*-
# This script is a command-line utility for interacting with Ethereum smart contracts with an emphasis on Minter contracts

import argparse
import os
import subprocess
import signal
import sys
import json
import threading
import time
import logging


from dotenv import load_dotenv
load_dotenv()  # Load .env file once

deploy_log = "./log/deploy-local.log"
abi_dir = "./out"

# Configure logging
logger = logging.getLogger('anvil')
console_handler = logging.StreamHandler()
formatter = logging.Formatter('%(levelname)s: %(message)s')
console_handler.setFormatter(formatter)
logger.addHandler(console_handler)

# Map verbosity levels to logging levels:
# -v    -> INFO     (20)
# -vv   -> DEBUG    (10)
# -vvv  -> TRACE    (5) - custom level
# -vvvv -> TRACE_DETAIL (1) - custom level with much more detail
logging.TRACE = 5
logging.TRACE_DETAIL = 1
logging.addLevelName(logging.TRACE, 'TRACE')
logging.addLevelName(logging.TRACE_DETAIL, 'TRACE_DETAIL')

def trace(self, message, *args, **kwargs):
    if self.isEnabledFor(logging.TRACE):
        self._log(logging.TRACE, message, args, **kwargs)

def trace_detail(self, message, *args, **kwargs):
    if self.isEnabledFor(logging.TRACE_DETAIL):
        self._log(logging.TRACE_DETAIL, message, args, **kwargs)

logging.Logger.trace = trace
logging.Logger.trace_detail = trace_detail

def set_verbosity(level):
    """
    Set verbosity level based on count of -v flags
    0: WARNING (default)
    1: INFO (-v)
    2: DEBUG (-vv)
    3: TRACE (-vvv)
    4+: TRACE_DETAIL (-vvvv)
    """
    if level == 0:
        logger.setLevel(logging.WARNING)
    elif level == 1:
        logger.setLevel(logging.INFO)
    elif level == 2:
        logger.setLevel(logging.DEBUG)
    elif level == 3:
        logger.setLevel(logging.TRACE)
    else:  # level >= 4
        logger.setLevel(logging.TRACE_DETAIL)

def quiet_run_command(command):
    """
    Run command and return result without checking exit code
    """
    cmd_str = " ".join(command)
    logger.debug(f"Running command: {cmd_str}")

    # Only print command at INFO level and above if we're executing cast/anvil operations
    if command[0] in ['cast', 'anvil']:
        logger.info(f">>> {cmd_str}")

    result = subprocess.run(command, capture_output=True, text=True)

    # Log stdout/stderr at different levels based on verbosity
    if result.stdout:
        logger.trace(f"Command stdout: {result.stdout.strip()}")
        # At TRACE_DETAIL level, we add details about environment and command execution
        logger.trace_detail(f"Full command details:\n  Command: {cmd_str}\n  Exit code: {result.returncode}\n  Full stdout: \n{result.stdout}")

    if result.stderr:
        # Always show stderr at regular TRACE level
        logger.trace(f"Command stderr: {result.stderr.strip()}")

    # Log return code at DEBUG level
    logger.debug(f"Command returned: {result.returncode}")

    return result

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
    if sig_input and '.' in sig_input and not contract_name:
        contract_name = sig_input.split('.', 1)[0]
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
            find_result = quiet_run_command([
                "find", abi_dir, "-name", f"{contract_name}.json", "-print", "-quit"
            ])

            if find_result.returncode == 0 and find_result.stdout.strip():
                found_error = search_abi_for_error(find_result.stdout.strip(), error_id, error_data)
                if found_error:
                    return found_error

        # Then search all contract ABIs
        logger.debug("Searching all contract ABIs for the error selector")
        find_all_result = quiet_run_command([
            "find", abi_dir, "-name", "*.json", "-type", "f"
        ])

        if find_all_result.returncode == 0 and find_all_result.stdout.strip():
            for abi_path in find_all_result.stdout.strip().split('\n'):
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
    contract_name = os.path.basename(abi_path).split('.')[0]

    # Extract errors using type filter
    error_result = quiet_run_command([
        "jq", '-c',
        '.abi[] | select(.type == "error")',
        abi_path
    ])

    if error_result.returncode == 0 and error_result.stdout.strip():
        logger.debug(f"Found errors in {contract_name}")

        # Process each error definition
        for error_json in error_result.stdout.strip().split('\n'):
            try:
                error = json.loads(error_json)
                name = error.get('name', '')
                inputs = error.get('inputs', [])

                if name:
                    # Create the error signature for calldata decoding
                    param_types = [input_param.get('type', '') for input_param in inputs]
                    sig = f"{name}({','.join(param_types)})"

                    # Calculate the selector to check for a match
                    selector_result = quiet_run_command(["cast", "keccak", sig])
                    if selector_result.returncode == 0:
                        # Get just the first 10 characters (0x + 8 for 4 bytes)
                        selector = selector_result.stdout.strip()[:10]
                        logger.debug(f"Error {name} has selector {selector}")

                        if selector == error_id:
                            logger.debug(f"Found matching error in {contract_name}: {sig}")

                            # Try to decode the full error data with parameters
                            decoded_params = ""

                            if len(error_data) > 10 and inputs:  # Contains parameters
                                calldata_result = quiet_run_command([
                                    "cast", "calldata", sig, error_data
                                ])
                                if calldata_result.returncode == 0 and calldata_result.stdout.strip():
                                    # Format parameter names if available
                                    param_info = []
                                    decoded_values = calldata_result.stdout.strip().split('\n')

                                    for i, param in enumerate(inputs):
                                        if i < len(decoded_values):
                                            param_name = param.get('name', f'param{i}')
                                            param_value = decoded_values[i].strip()
                                            param_info.append(f"{param_name}={param_value}")

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

def run_command(command):
    """
    Run command and exit if it fails
    """
    result = quiet_run_command(command)

    # Exit on failure
    if result.returncode != 0:
        print(f"*** Command failed: {' '.join(command)}")

        # Extract command info for better error context
        cmd_type = command[0] if command else "Unknown"
        sig_input = None
        if len(command) > 3 and cmd_type in ["cast"] and command[1] in ["call", "send"]:
            # For call/send, the signature is the 3rd arg
            sig_input = command[3] if len(command) > 3 else None
            # Also extract the contract we're calling
            contract_addr = command[2] if len(command) > 2 else None

        if result.stderr:
            error_msg = result.stderr.strip()

            # Look for custom error pattern in the error message
            custom_error_match = None
            if "custom error" in error_msg:
                import re
                # Extract the custom error data
                custom_error_match = re.search(r'custom error ([^,\s]+)(?:, data: "([^"]+)")?', error_msg)

            if custom_error_match:
                error_selector = custom_error_match.group(1)
                error_data = custom_error_match.group(2) if custom_error_match.group(2) else error_selector

                # Try to decode the error with context from the command
                decoded_error, raw_data = decode_custom_error(error_data, sig_input=sig_input)

                # Print both decoded error and raw data
                print(f"*** {decoded_error}")
                print(f"*** Raw error data: {raw_data}")
            else:
                print(f"*** Error: {error_msg}")

        if result.stdout:
            print(f"*** Output: {result.stdout.strip()}")

        print(f"*** Exit code: {result.returncode}")
        sys.exit(result.returncode)

    return result

def with_impersonation(network, identity, callback_func, *callback_args, **callback_kwargs):
    """
    Execute a function with optional impersonation

    Args:
        network: Network name
        identity: Address to impersonate (if None, no impersonation happens)
        callback_func: Function to execute
        *callback_args, **callback_kwargs: Arguments to pass to the callback function
    """
    if identity:
        # Set up impersonation
        impersonation_address = address_of(network, identity)
        run_command(["cast", "rpc", "anvil_impersonateAccount", impersonation_address])
        try:
            # Execute the callback with the impersonation address
            return callback_func(impersonation_address, *callback_args, **callback_kwargs)
        finally:
            # Clean up impersonation
            run_command(["cast", "rpc", "anvil_stopImpersonatingAccount", impersonation_address])
    else:
        # No impersonation needed, just run the function without an impersonation address
        return callback_func(None, *callback_args, **callback_kwargs)

def bcinfo(network, name, field="address"):
    # Use quiet version since bcinfo might legitimately fail
    result = quiet_run_command(["lib/bao-base/run", "-q", "bcinfo", network, name, field])
    return result.stdout.strip()

def address_of(network, wallet):
    if wallet.startswith("0x"):
        return wallet
    elif wallet == "me":
        pk = os.getenv("PRIVATE_KEY")
        if pk:
            # Wallet address conversion shouldn't fail
            result = run_command(["cast", "wallet", "address", "--private-key", pk])
            return result.stdout.strip()
        else:
            print("error: no private key found in env")
            sys.exit(1)
    else:
        address = bcinfo(network, wallet)
        if not address and os.path.isfile(deploy_log):
            with open(deploy_log) as f:
                data = json.load(f)
                address = data.get("addresses", {}).get(wallet, "")
        if not address:
            address = wallet
        return address

def role_number_of(network, role, on):
    if role.startswith("0x") or role.isdigit():
        return role
    on_address = address_of(network, on)
    result = run_command(["cast", "call", on_address, f"{role}()(uint256)"])
    output = result.stdout.strip().split()
    if not output:
        raise ValueError(f"Role {role} not found on {on}")
    return output[0]

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
    result = run_command([
        "find", abi_dir, "-name", f"{contract}.json", "-print", "-quit"
    ])
    abi_path = result.stdout.strip()
    if not abi_path:
        print(f"error: Contract ABI file not found for {contract}")
        sys.exit(1)

    # Get detailed function information including inputs and outputs
    result = run_command([
        "jq",
        f'.abi[] | select(.name == "{func_name}" and .type == "function")',
        abi_path
    ])

    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: Function {func_name} not found in contract {contract}")
        sys.exit(1)

    try:
        func_data = json.loads(result.stdout.strip())

        # Extract parameter types for the signature
        param_types = [input_param.get('type', '') for input_param in func_data.get('inputs', [])]
        param_str = ','.join(param_types)

        return {
            'signature': f"{func_name}({param_str})",
            'param_types': param_types,
            'inputs': func_data.get('inputs', []),
            'outputs': func_data.get('outputs', []),
            'abi_path': abi_path
        }
    except json.JSONDecodeError:
        print(f"error: Invalid JSON in ABI for {contract}.{func_name}")
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
    if '(' in sig_input:
        # Case 1: It's already a function signature
        func_name = sig_input[:sig_input.find('(')]
        param_str = sig_input[sig_input.find('(')+1:sig_input.find(')')]
        param_types = param_str.split(',') if param_str else []
        return sig_input, param_types
    elif '.' in sig_input:
        # Case 2: It's in contract.function format
        contract, func_name = sig_input.split('.', 1)
        func_info = get_function_info(contract, func_name)
        return func_info['signature'], func_info['param_types']
    else:
        print(f"*** Error: Invalid signature format '{sig_input}'")
        print("*** Signature must be either 'function(type1,type2)' or 'Contract.function'")
        sys.exit(1)

def grab(network, wallet, eth_amount):
    address = address_of(network, wallet)
    wei_amount = run_command(["cast", "to-wei", eth_amount]).stdout.strip()
    run_command(["cast", "rpc", "anvil_setBalance", address, run_command(["cast", "to-hex", wei_amount]).stdout.strip()])
    wei_balance = run_command(["cast", "balance", address]).stdout.strip()
    eth_balance = run_command(["cast", "from-wei", wei_balance]).stdout.strip()
    print(f"*** {wallet} balance is now {eth_balance}")

def grab_erc20(network, wallet, eth_amount, token):
    """
    Get ERC20 tokens for a wallet by impersonating holders from the event logs
    using JSON format for easier parsing
    """
    wallet_address = address_of(network, wallet)
    token_address = address_of(network, token)

    # Check current balance
    wei_balance = run_command(["cast", "call", token_address, "balanceOf(address)(uint256)", wallet_address]).stdout.strip().split()[0]
    eth_balance = run_command(["cast", "from-wei", wei_balance]).stdout.strip()
    print(f"*** giving {wallet} {eth_amount} erc20 {token} (current: {eth_balance})...")

    # Convert to wei
    wei_amount = int(run_command(["cast", "to-wei", eth_amount]).stdout.strip())

    # Track progress
    wei_amount_transferred = 0
    done = [wallet_address.lower()]  # Use lowercase for consistent comparison

    # Start with recent blocks
    latest_block = int(run_command(["cast", "block", "latest", "-f", "number"]).stdout.strip())
    block_window = 2000
    blocks_to_check = [(latest_block - block_window, latest_block)]

    # Process blocks until we have enough tokens or run out of blocks
    while blocks_to_check and wei_amount_transferred < wei_amount:
        start_block, end_block = blocks_to_check.pop(0)
        if start_block < 0:
            start_block = 0

        # Get Transfer events using JSON output for easier parsing
        logger.debug(f"Checking blocks {start_block} to {end_block}")
        events = quiet_run_command([
            "cast", "logs",
            "--from-block", str(start_block),
            "--to-block", str(end_block),
            "--address", token_address,
            "Transfer(address,address,uint256)",
            "--json"  # Request JSON output format
        ])

        # Skip if error or no events
        if events.returncode != 0 or not events.stdout.strip():
            # Queue earlier blocks to check
            if start_block > 0:
                new_end = start_block - 1
                new_start = max(0, new_end - block_window)
                blocks_to_check.append((new_start, new_end))
            continue

        # Parse JSON events
        try:
            import json
            logs = json.loads(events.stdout)
            logger.debug(f"Found {len(logs)} Transfer events")

            # Process each event
            recipients = []
            for log in logs:
                # Standard ERC20 Transfer event has:
                # topics[0]: Event signature
                # topics[1]: From address (indexed)
                # topics[2]: To address (indexed)
                # data: Amount (not indexed)
                topics = log.get('topics', [])
                if len(topics) >= 3:
                    # Extract 'to' address from topics[2]
                    # Topic values are 32 bytes (64 hex chars + 0x), but addresses are 20 bytes (40 hex chars)
                    padded_to_address = topics[2]
                    # Take the last 40 characters (20 bytes) to get the address
                    to_address = "0x" + padded_to_address[-40:]
                    recipients.append(to_address.lower())
        except json.JSONDecodeError:
            logger.debug("Failed to parse JSON output from cast logs")
            # If we can't parse the JSON, just skip this block range and try another
            if start_block > 0:
                new_end = start_block - 1
                new_start = max(0, new_end - block_window)
                blocks_to_check.append((new_start, new_end))
            continue

        logger.debug(f"Found {len(recipients)} potential token holders")

        # Process each unique recipient
        for to_address in set(recipients):
            # Skip already processed or zero address
            if to_address in done or to_address == "0x0000000000000000000000000000000000000000":
                continue

            done.append(to_address)
            logger.debug(f"Checking balance of: {to_address}")

            try:
                # Get token balance of this address
                balance_result = quiet_run_command([
                    "cast", "call", token_address,
                    "balanceOf(address)(uint256)",
                    to_address
                ])

                if balance_result.returncode != 0 or not balance_result.stdout.strip():
                    continue

                wei_pawn_holding = int(balance_result.stdout.strip().split()[0])

                # Only process addresses with meaningful balances
                if wei_pawn_holding > 1000000:  # Small threshold to catch more token holders
                    # Calculate how much to take (90% of their balance, capped at what we still need)
                    wei_to_steal = min(wei_pawn_holding * 9 // 10, wei_amount - wei_amount_transferred)
                    eth_to_steal = run_command(["cast", "from-wei", str(wei_to_steal)]).stdout.strip()

                    print(f"*** stealing {eth_to_steal} of {token} from {to_address}...")

                    # Use the with_impersonation helper
                    def transfer_tokens(impersonated_address):
                        # Give the address some ETH to pay for gas
                        run_command(["cast", "rpc", "anvil_setBalance",
                                    to_address,
                                    run_command(["cast", "to-hex", "27542757796200000000"]).stdout.strip()])

                        # Transfer tokens
                        run_command(["cast", "send",
                                    token_address,
                                    "transfer(address,uint256)",
                                    wallet_address,
                                    str(wei_to_steal),
                                    "--from", impersonated_address,
                                    "--unlocked"])

                    # Execute the transfer with impersonation
                    with_impersonation(network, to_address, transfer_tokens)

                    # Update tracking variables
                    wei_amount_transferred += wei_to_steal
                    eth_amount_transferred = run_command(["cast", "from-wei", str(wei_amount_transferred)]).stdout.strip()
                    print(f"*** total amount stolen so far: {eth_amount_transferred} of {eth_amount}")

                    # Exit if we have enough
                    if wei_amount_transferred >= wei_amount:
                        return

            except Exception as e:
                logger.debug(f"Error processing address {to_address}: {str(e)}")

        # Queue up earlier blocks to check if we need more tokens
        if wei_amount_transferred < wei_amount and start_block > 0:
            new_end = start_block - 1
            new_start = max(0, new_end - block_window)
            blocks_to_check.append((new_start, new_end))

    # If we still couldn't find enough tokens
    if wei_amount_transferred < wei_amount:
        remaining = wei_amount - wei_amount_transferred
        remaining_eth = run_command(["cast", "from-wei", str(remaining)]).stdout.strip()
        print(f"*** Warning: Could only find {eth_amount_transferred} of requested {eth_amount} tokens")
        print(f"*** Missing {remaining_eth} tokens. Try checking more blocks or a different token.")

def start(network, chain_id=None):
    # Store the anvil process so we can terminate it properly
    anvil_process = None

    def wait_for_anvil():
        while quiet_run_command(["nc", "-z", "localhost", "8545"]).returncode != 0:
            time.sleep(1)
        print("*** allowing baomultisig to be impersonated...")
        run_command(["cast", "rpc", "anvil_impersonateAccount", bcinfo(network, "baomultisig")])
        grab(network, "baomultisig", "1")

    def signal_handler(sig, frame):
        print("\n*** Terminating anvil process...")
        if anvil_process:
            # Use os.kill instead of process.terminate() for more forceful termination
            try:
                os.kill(anvil_process.pid, signal.SIGTERM)
                time.sleep(0.5)  # Give it a brief moment to terminate gracefully

                # If still running, force kill
                if anvil_process.poll() is None:
                    os.kill(anvil_process.pid, signal.SIGKILL)
                    print("*** Forcefully killed anvil process")
            except OSError as e:
                print(f"Error terminating process: {e}")

        # Exit without calling any other handlers
        os._exit(0)

    # Register the signal handler for CTRL+C (SIGINT)
    original_handler = signal.signal(signal.SIGINT, signal_handler)

    try:
        anvil_thread = threading.Thread(target=wait_for_anvil)
        anvil_thread.daemon = True  # Make thread a daemon so it exits when main thread exits
        anvil_thread.start()

        # Use subprocess.Popen instead of run_command for direct process control
        # Don't pipe stdout/stderr to avoid buffer issues that might block termination
        cmd = ["anvil", "-f", network]

        # Add chain-id if specified
        if chain_id:
            cmd.extend(["--chain-id", str(chain_id)])

        logger.info(f">>> {' '.join(cmd)}")
        anvil_process = subprocess.Popen(cmd)

        # Wait for anvil process to complete or be interrupted
        anvil_process.wait()
    finally:
        # Restore original signal handler
        signal.signal(signal.SIGINT, original_handler)
        # Make absolutely sure the process is terminated
        if anvil_process and anvil_process.poll() is None:
            try:
                os.kill(anvil_process.pid, signal.SIGKILL)
            except OSError:
                pass

def format_call_result(stdout, sig_input=None, network=None):
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
    if sig_input and '.' in sig_input:
        try:
            contract, func_name = sig_input.split('.', 1)
            func_info = get_function_info(contract, func_name)
            if func_info and func_info['outputs'] and len(func_info['outputs']) > 0:
                output_type = func_info['outputs'][0].get('type')
        except Exception as e:
            logger.debug(f"Error getting output type from ABI: {e}")

    # Handle specific output types
    if output_type:
        logger.debug(f"Function returns type: {output_type}")

        # Integer types (uint*, int*)
        if output_type.startswith(('uint', 'int')):
            if result.startswith('0x'):
                try:
                    decimal_value = int(result, 16)
                    return f"{decimal_value}"  # Just show decimal for ints
                except ValueError:
                    pass

        # Boolean type
        elif output_type == 'bool':
            if result == '0x0' or result == '0':
                return "false"
            elif result == '0x1' or result == '1':
                return "true"

        # Address type
        elif output_type == 'address':
            # Just return the address as is
            return result

        # Bytes and string types
        elif output_type.startswith(('bytes', 'string')):
            # Try to decode if it looks like hex
            if result.startswith('0x'):
                try:
                    # Try to decode as string if it's UTF-8 encodable
                    bytes_value = bytes.fromhex(result[2:])
                    string_value = bytes_value.decode('utf-8', errors='replace')
                    if all(c.isprintable() or c.isspace() for c in string_value):
                        return f"{result} (decoded: \"{string_value}\")"
                except (ValueError, UnicodeDecodeError):
                    pass

    # Default formatting based on the output content
    if result.startswith('0x'):
        try:
            # Convert hex to decimal if it's a hex number
            decimal_value = int(result, 16)
            # Return both hex and decimal representation
            return f"{decimal_value}"
        except ValueError:
            # If not a valid hex number, just return as is
            return result

    # For array or structured output (multi-line)
    if '\n' in result:
        return f"\n{result}"

    # Default case
    return result

def main():
    # Create the top-level parser with better help
    parser = argparse.ArgumentParser(
        description="Anvil script for interacting with Ethereum contracts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  anvil.py start -f mainnet                             # Start anvil forked from mainnet
  anvil.py start -f mainnet --chain-id 1                # Start anvil with specific chain ID
  anvil.py steal --to me --amount 100                   # Add 100 ETH to your account
  anvil.py steal --to me --amount 1 --erc20 wsteth      # Add 1 wstETH to your account
  anvil.py grant --role MINTER_ROLE --on token --to me  # Grant role on contract
  anvil.py sig ERC20.transfer                           # Show function signature
        """
    )

    # Add global arguments
    parser.add_argument("-f", "--rpc-url", dest="network", default="mainnet", help="Network to fork from")
    parser.add_argument("-v", action="count", default=0, help="Increase verbosity level")

    # Create subparsers for commands
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")
    subparsers.required = False  # Make subcommand optional, default to "start"

    # Start command
    start_parser = subparsers.add_parser("start", help="Start anvil instance")
    start_parser.add_argument("--chain-id", type=int, help="Specify chain ID for the anvil instance")

    # Steal command and aliases
    steal_aliases = ["pinch", "nick", "grab", "pilfer", "embezzle", "rob", "swipe", "thieve",
                     "filch", "purloin", "lift", "pillage", "plunder", "loot", "snatch"]
    steal_parser = subparsers.add_parser("steal", help="Add tokens to an address", aliases=steal_aliases)
    steal_parser.add_argument("--erc20", help="ERC20 token address or name (if omitted, steals ETH)")
    steal_parser.add_argument("--to", required=True, help="Recipient address")
    steal_parser.add_argument("--amount", required=True, help="Amount of tokens to transfee")

    # Grant command
    grant_parser = subparsers.add_parser("grant", help="Grant a role on a contract")
    grant_parser.add_argument("--role", required=True, help="Role identifier/name")
    grant_parser.add_argument("--on", required=True, help="Contract address with role system")
    grant_parser.add_argument("--to", required=True, help="Address to receive the role")
    grant_parser.add_argument("--as", dest="as_", help="Address to impersonate when granting")

    # Call command
    call_parser = subparsers.add_parser("call", help="Read-only call to contract")
    call_parser.add_argument("--to", required=True, help="Contract address")
    call_parser.add_argument("--sig", required=True,
                           help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')")
    call_parser.add_argument("--as", dest="as_", help="Address to impersonate for the call")
    call_parser.add_argument("args", nargs=argparse.REMAINDER, help="Arguments to pass to function")

    # Send command
    send_parser = subparsers.add_parser("send", help="State-changing transaction to contract")
    send_parser.add_argument("--to", required=True, help="Contract address")
    send_parser.add_argument("--sig", required=True,
                           help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')")
    send_parser.add_argument("--as", dest="as_", help="Address to impersonate for the transaction")
    send_parser.add_argument("args", nargs=argparse.REMAINDER, help="Arguments to pass to function")

    # Sig command
    sig_parser = subparsers.add_parser("sig", help="Look up function signature")
    sig_parser.add_argument("signature",
                           help="Either a function signature (e.g., 'transfer(address,uint256)') or Contract.function (e.g., 'ERC20.transfer')")

    # Parse arguments
    args = parser.parse_args()

    # Set the default command if none provided
    if not args.command:
        args.command = "start"

    # Set up logging based on verbosity level
    set_verbosity(args.v)

    # Convert count to Foundry's verbosity flag format (e.g., -vvv)
    verbosity = "-" + "v" * args.v if args.v > 0 else ""

    logger.info(f"Processing command: {args.command}")

    # Execute commands
    if args.command in ["steal"] + steal_aliases:
        if args.erc20:
            print(f"*** transfer {args.to} {args.amount} ERC20 {args.erc20}")
            grab_erc20(args.network, args.to, args.amount, args.erc20)
        else:
            print(f"*** transfer {args.to} {args.amount} ETH")
            grab(args.network, args.to, args.amount)

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
        run_command(["cast", "send", on_address, "grantRoles(address,uint256)",
                    to_address, role_number] + auth_flags)

    elif args.command in ["call", "send"]:
        to_address = address_of(args.network, args.to)
        to = f"{args.to} ({to_address})" if to_address != args.to else args.to
        if args.as_:
            as_address = address_of(args.network, args.as_)
            as_ = " as " + args.as_  + " (" + as_address + ")" if as_address !=  args.as_ else ""
        else:
            as_address = None
            as_ = ""
        # Parse the signature
        sig, param_types = parse_sig(args.network, args.sig)

        # Apply address_of to any argument that corresponds to an address type
        processed_args = []
        for i, arg in enumerate(args.args):
            # Check if this parameter is an address type
            is_address = (i < len(param_types) and 'address' in param_types[i])

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
        result = with_impersonation(args.network, args.as_, lambda as_address: (
            run_command(["cast", args.command, to_address, sig] + processed_args +
                          (auth_flags if args.command == "send" else []) +
                          ([verbosity] if verbosity else []))
        ))

        # For 'call' operations, show the result
        if args.command == "call" and result.stdout:
            formatted_result = format_call_result(result.stdout, args.sig, args.network)
            print(f"Result: {formatted_result}")

    elif args.command == "start":
        start(args.network, args.chain_id)

    elif args.command == "sig":
        # Parse the signature format using the same parser as call/send
        if '.' in args.signature:
            contract, func_name = args.signature.split('.', 1)
            func_info = get_function_info(contract, func_name)

            output = f"*** signature for {contract}.{func_name} is \"{func_info['signature']}\""

            # Display input parameters if available
            if func_info['inputs']:
                output += "\nInput Parameters:"
                for i, param in enumerate(func_info['inputs']):
                    name = param.get('name', 'unnamed')
                    type_name = param.get('type', '')
                    output += f"\n  {i+1}. {name}: {type_name}"

            # Display return parameters if available
            if func_info['outputs']:
                output += "\nReturn Values:"
                for i, param in enumerate(func_info['outputs']):
                    name = param.get('name', f'return_{i}')
                    type_name = param.get('type', '')
                    output += f"\n  {i+1}. {name}: {type_name}"

            print(output)
        else:
            print(f"*** error: When using a raw function signature, you must use the Contract.function format")
            sys.exit(1)

if __name__ == "__main__":
    main()
