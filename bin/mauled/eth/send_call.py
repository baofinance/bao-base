"""
Shared functionality between the send and call commands.

Both commands have similar argument structures and execution patterns,
so common code is extracted here to avoid duplication.
"""

import sys
from typing import List, Tuple

from mauled.core.logging import get_logger

from bin.mauled.eth.abi import get_function_info

logger = get_logger()


def parse_sig(network: str, sig_input: str) -> Tuple[str, List[str]]:
    """
    Parse a signature input which can be either:
    1. A full function signature like 'transfer(address,uint256)'
    2. A contract.function format like 'ERC20.transfer'

    Args:
        network: Network name
        sig_input: Signature input string

    Returns:
        Tuple of (signature_string, param_types)
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
        print("*** Signature must be either 'function(type1,type2)' or 'Contract.function'")
        sys.exit(1)


def format_call_result(stdout: str, sig_input: str, network: str = None) -> str:
    """
    Format call result based on the output content and expected return type from ABI

    Args:
        stdout: The stdout from the cast call command
        sig_input: The signature input (e.g. 'ERC20.balanceOf')
        network: The network being used (for context)

    Returns:
        Formatted result string
    """
    from bin.maul import get_function_info  # Import here to avoid circular dependencies

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
