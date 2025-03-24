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

def usage():
    print("Usage: anvil.py -f <network> [command] [options]")
    print("Commands:")
    print("  steal [--erc20 <token>] --to <address> --amount <amount>")
    print("  grant --role <number> --on <address> --to <address> [--as <address>]")
    print("  call --to <address> [--sig <function(parameters)> | --contract <contract> --function <function>] [--as <address>] [args...]")
    print("  send --to <address> [--sig <function(parameters)> | --contract <contract> --function <function>] [--as <address>] [args...]")
    print("  start (default)")
    sys.exit(1)

def run_command(command):
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
    result = run_command(["lib/bao-base/run", "-q", "bcinfo", network, name, field])
    return result.stdout.strip()

def address_of(network, wallet):
    if wallet.startswith("0x"):
        return wallet
    elif wallet == "me":
        pk = os.getenv("PRIVATE_KEY")
        if pk:
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

def find_contract_abi(contract):
    """Find and return the path to the contract's ABI file"""
    result = run_command([
        "find", abi_dir, "-name", f"{contract}.json", "-print", "-quit"
    ])
    abi_path = result.stdout.strip()
    if not abi_path:
        print(f"error: Contract ABI file not found for {contract}")
        sys.exit(1)
    return abi_path

def lookup_sig(contract, func_name):
    # First, find the contract ABI file
    abi_path = find_contract_abi(contract)

    # Use jq to extract the function signature
    result = run_command([
        "jq", "-r",
        f'.abi[] | select(.name == "{func_name}" and .type == "function") | .inputs | map(.type) | join(",")',
        abi_path
    ])

    params = result.stdout.strip()
    if result.returncode != 0 or not result.stdout:
        print(f"error: Function {func_name} not found in contract {contract}")
        sys.exit(1)

    return f"{func_name}({params})"

def get_function_param_names(contract, func_name):
    """Get the parameter names for a function"""
    abi_path = find_contract_abi(contract)

    # Use simpler jq syntax that outputs valid JSON
    result = run_command([
        "jq",
        f'.abi[] | select(.name == "{func_name}" and .type == "function")',
        abi_path
    ])

    if result.returncode != 0 or not result.stdout.strip():
        return None

    try:
        func_info = json.loads(result.stdout.strip())
        return {
            'inputs': func_info.get('inputs', []),
            'outputs': func_info.get('outputs', [])
        }
    except json.JSONDecodeError:
        return None

def grab(network, wallet, eth_amount):
    address = address_of(network, wallet)
    wei_amount = run_command(["cast", "to-wei", eth_amount]).stdout.strip()
    run_command(["cast", "rpc", "anvil_setBalance", address, run_command(["cast", "to-hex", wei_amount]).stdout.strip()])
    wei_balance = run_command(["cast", "balance", address]).stdout.strip()
    eth_balance = run_command(["cast", "from-wei", wei_balance]).stdout.strip()
    print(f"*** {wallet} balance is now {eth_balance}")

def grab_erc20(network, wallet, eth_amount, token):
    wallet_address = address_of(network, wallet)
    token_address = address_of(network, token)
    wei_balance = run_command(["cast", "call", token_address, "balanceOf(address)(uint256)", wallet_address]).stdout.strip().split()[0]
    eth_balance = run_command(["cast", "from-wei", wei_balance]).stdout.strip()
    print(f"*** giving {wallet} {eth_amount} erc20 {token} (current: {eth_balance})...")
    wei_amount = run_command(["cast", "to-wei", eth_amount]).stdout.strip()
    done = [wallet_address]
    latest_block = int(run_command(["cast", "block", "latest", "-f", "number"]).stdout.strip())
    start_block = latest_block - 2000
    end_block = latest_block
    wei_amount_transferred = 0
    while end_block >= 0:
        events = run_command(["cast", "logs", "--from-block", str(start_block), "--to-block", str(end_block), "--address", token_address, "Transfer(address,address,uint256)"]).stdout.strip()
        for line in events.splitlines():
            if "topics:" in line:
                to = "0x" + line.split()[1][26:]
                if to.startswith("0x") and to not in done:
                    done.append(to)
                    wei_pawn_holding = run_command(["cast", "call", token_address, "balanceOf(address)(uint256)", to]).stdout.strip().split()[0]
                    if int(wei_pawn_holding) > 10000000000000:
                        wei_to_steal = min(int(wei_pawn_holding) * 9 // 10, int(wei_amount) - wei_amount_transferred)
                        eth_to_steal = run_command(["cast", "from-wei", str(wei_to_steal)]).stdout.strip()
                        print(f"*** stealing {eth_to_steal} of {token} from {to}...")
                        run_command(["cast", "rpc", "anvil_impersonateAccount", to])
                        run_command(["cast", "rpc", "anvil_setBalance", to, run_command(["cast", "to-hex", "27542757796200000000"]).stdout.strip()])
                        run_command(["cast", "send", token_address, "transfer(address,uint256)", wallet_address, str(wei_to_steal), "--from", to, "--unlocked"])
                        run_command(["cast", "rpc", "anvil_stopImpersonatingAccount", to])
                        wei_amount_transferred += wei_to_steal
                        eth_amount_transferred = run_command(["cast", "from-wei", str(wei_amount_transferred)]).stdout.strip()
                        print(f"*** total amount stolen so far: {eth_amount_transferred} of {eth_amount}")
                        if wei_amount_transferred >= int(wei_amount):
                            return
        end_block = start_block - 1
        start_block = end_block - 2000
        if start_block < 0:
            start_block = 0

def lookup_env(env_name):
    value = os.getenv(env_name, "")
    if not value and os.path.isfile(".env"):
        with open(".env") as f:
            for line in f:
                if line.startswith(env_name + "="):
                    value = line.strip().split("=", 1)[1]
                    break
    return value

def execute_function(network, command, to, sig, contract, function_name, as_address, args, verbosity):
    to_address = address_of(network, to)
    as_address = address_of(network, as_address) if as_address else None
    if not sig:
        sig = lookup_sig(contract, function_name)
    print(f"*** {command} to {to} with signature {sig} as {as_address}...")
    with_impersonation(network, as_address, lambda as_address: (
        run_command(["cast", command, to_address, sig] + args +
                      (["--from", as_address] if as_address else []) +
                      ([verbosity] if verbosity else []))
    ))

def start(network):
    def wait_for_anvil():
        while run_command(["nc", "-z", "localhost", "8545"]).returncode != 0:
            time.sleep(1)
        print("*** allowing baomultisig to be impersonated...")
        run_command(["cast", "rpc", "anvil_impersonateAccount", bcinfo(network, "baomultisig")])
        grab(network, "baomultisig", "1")

    anvil_thread = threading.Thread(target=wait_for_anvil)
    anvil_thread.start()
    run_command(["anvil", "-f", network])
    anvil_thread.join()

def main():
    # get the common args
    parser = argparse.ArgumentParser(description="Anvil script")
    parser.add_argument("-f", "--rpc-url", dest="network", default="mainnet", help="RPC URL")
    parser.add_argument("-v", action="count", default=0, help="Verbosity level")
    parser.add_argument("command", nargs="?", default="start", help="Command to execute")
    global_args, remaining_args = parser.parse_known_args()

    # Set up logging based on verbosity level
    set_verbosity(global_args.v)

    # Convert count to Foundry's verbosity flag format
    # e.g., -vvv becomes "-vvv"
    verbosity = "-" * global_args.v

    logger.info(f"Processing command: {global_args.command}")

    # get the command specific args
    parser = argparse.ArgumentParser(description=f"Anvil script - {global_args.command} command")


    if global_args.command in ["steal", "pinch", "nick", "grab", "pilfer", "embezzle", "rob", "swipe", "thieve", "filch", "purloin", "lift", "pillage", "plunder", "loot", "snatch"]:
        parser.add_argument("--erc20", help="ERC20 token")
        parser.add_argument("--to", required=True, help="Recipient address")
        parser.add_argument("--amount", required=True, help="Amount")
        command_args = parser.parse_args(remaining_args)
        if command_args.erc20:
            print(f"*** transfer {command_args.to} {command_args.amount} ERC20 {command_args.erc20}")
            grab_erc20(global_args.network, command_args.to, command_args.amount, command_args.erc20)
        else:
            print(f"*** transfer {command_args.to} {command_args.amount} ETH")
            grab(global_args.network, command_args.to, command_args.amount)

    elif global_args.command == "grant":
        parser.add_argument("--role", required=True, help="Role number")
        parser.add_argument("--on", required=True, help="On address")
        parser.add_argument("--to", required=True, help="Recipient address")
        parser.add_argument("--as", dest="as_", help="As address")
        command_args = parser.parse_args(remaining_args)

        on_address = address_of(global_args.network, command_args.on)
        to_address = address_of(global_args.network, command_args.to)
        role_number = role_number_of(global_args.network, command_args.role, on_address)
        print(f"*** grant role {command_args.role} on {command_args.on} to {command_args.to} as {command_args.as_}...")
        with_impersonation(global_args.network, command_args.as_, lambda as_address:
            run_command(["cast", "send", on_address, "grantRoles(address,uint256)",
                          to_address, role_number] +
                          (["--from", as_address, "--unlocked"] if as_address else [])))

    elif global_args.command in ["call", "send"]:
        parser.add_argument("--to", required=True, help="Recipient address")
        parser.add_argument("--sig", help="Function signature")
        parser.add_argument("--contract", help="Contract name")
        parser.add_argument("--function", help="Function name")
        parser.add_argument("--as", dest="as_", help="As address")
        parser.add_argument("args", nargs=argparse.REMAINDER, help="Additional arguments")
        command_args = parser.parse_args(remaining_args)
        execute_function(global_args.network, global_args.command, command_args.to, command_args.sig, command_args.contract, command_args.function, command_args.as_, command_args.args, verbosity)
    elif global_args.command == "start":
        start(global_args.network)
    elif global_args.command == "sig":
        parser.add_argument("--contract", required=True, help="Contract name")
        parser.add_argument("--function", required=True, help="Function name")
        command_args = parser.parse_args(remaining_args)
        sig = lookup_sig(command_args.contract, command_args.function)

        # Get and display parameter names
        func_info = get_function_param_names(command_args.contract, command_args.function)
        output = f"*** signature for {command_args.contract}.{command_args.function} is \"{sig}\""

        # Display input parameters if available
        if func_info and func_info['inputs']:
            output += "\nInput Parameters:"
            for i, param in enumerate(func_info['inputs']):
                name = param.get('name', 'unnamed')
                type_name = param.get('type', '')
                output += f"\n  {i+1}. {name}: {type_name}"

        # Display return parameters if available
        if func_info and func_info['outputs']:
            output += "\nReturn Values:"
            for i, param in enumerate(func_info['outputs']):
                name = param.get('name', f'return_{i}')
                type_name = param.get('type', '')
                output += f"\n  {i+1}. {name}: {type_name}"

        print(output)
    else:
        usage()

if __name__ == "__main__":
    main()
