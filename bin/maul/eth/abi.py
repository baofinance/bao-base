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
    ABI_DIR = os.getenv("ABI_DIR", "./out")
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


def get_function_info(contract, func_name):
    """
    Get comprehensive information about a function from its ABI

    Args:
        contract: Contract name to look up
        func_name: Function name to look up

    Returns:
        dict: Dictionary containing function information
    """
    ABI_DIR = os.getenv("ABI_DIR", "./out")

    # Find the contract ABI file
    result = run_command(
        ["find", ABI_DIR, "-name", f"{contract}.json", "-print", "-quit"]
    )
    abi_path = result.stdout.strip()
    if not abi_path:
        logger.error(f"Contract ABI file not found for {contract}")
        raise FileNotFoundError(f"ABI file not found for {contract}")

    # Get detailed function information including inputs and outputs
    result = run_command(
        [
            "jq",
            f'.abi[] | select(.name == "{func_name}" and .type == "function")',
            abi_path,
        ]
    )
    if result.returncode != 0 or not result.stdout.strip():
        logger.error(f"Function {func_name} not found in contract {contract}")
        raise ValueError(f"Function {func_name} not found in contract {contract}")

    try:
        func_data = json.loads(result.stdout.strip())
        # Extract parameter types for the signature
        param_types = [
            input_param.get("type", "") for input_param in func_data.get("inputs", [])
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
        logger.error(f"Invalid JSON in ABI for {contract}.{func_name}")
        raise ValueError(f"Invalid JSON in ABI for {contract}.{func_name}")


def format_call_result(stdout, sig_input=None, network=None):
    """
    Format call result based on the output content and expected return type from ABI

    Args:
        stdout: The stdout from the cast call command
        sig_input: The signature input (e.g. 'ERC20.balanceOf')
        network: The network being used (for context)
    """
    result = stdout
    if hasattr(stdout, "stdout"):
        result = stdout.stdout

    result = result.strip()

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
            else:
                try:
                    decimal_value = int(result)
                    return f"{decimal_value}"  # Keep decimal format for readability
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
                try:
                    decimal_value = int(result)
                    return f"0x{decimal_value:040x}"
                except ValueError:
                    pass

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

    # Default case
    if "\n" in result:
        return f"\n{result}"
    return result


def parse_sig(signature, network=None):
    """
    Parse a function signature into its components.

    Handles both Contract.function format and direct function(param,param) format.

    Args:
        signature: Function signature to parse
        network: Optional network context

    Returns:
        dict: Structured information about the signature
    """
    # Initialize result structure
    result = {"signature": None, "function": None, "inputs": [], "outputs": []}

    # Handle Contract.function format
    if "." in signature and "(" not in signature:
        contract_name, function_name = signature.split(".", 1)
        result["contract"] = contract_name

        # Get function info from ABI (simplified for now)
        # In a real implementation, we'd look up the full ABI
        from .contracts import get_contract_abi

        try:
            contract_abi = get_contract_abi(contract_name, network)
            for item in contract_abi:
                if item.get("type") == "function" and item.get("name") == function_name:
                    result["function"] = function_name
                    result["inputs"] = item.get("inputs", [])
                    result["outputs"] = item.get("outputs", [])

                    # Build signature string
                    param_types = [inp.get("type", "") for inp in result["inputs"]]
                    result["signature"] = f"{function_name}({','.join(param_types)})"
                    return result

            # Function not found in ABI
            raise ValueError(
                f"Function {function_name} not found in {contract_name} ABI"
            )

        except Exception as e:
            logger.error(f"Error parsing function signature: {e}")
            raise

    # Handle direct function signature format
    elif "(" in signature and ")" in signature:
        # Extract function name and parameters
        match = re.match(r"^(\w+)\((.*)\)$", signature)
        if not match:
            raise ValueError(f"Invalid function signature: {signature}")

        function_name, params_str = match.groups()
        result["function"] = function_name
        result["signature"] = signature

        # Parse parameter types
        if params_str:
            param_types = [p.strip() for p in params_str.split(",") if p.strip()]
            for i, param_type in enumerate(param_types):
                result["inputs"].append({"type": param_type, "name": f"param{i}"})

        return result

    else:
        raise ValueError(f"Invalid signature format: {signature}")


def ether_to_wei(ether_amount):
    """Convert ether amount to wei."""
    result = run_command(["cast", "to-wei", str(ether_amount)])
    return result.stdout.strip()


def wei_to_ether(wei_amount):
    """Convert wei amount to ether."""
    result = run_command(["cast", "from-wei", str(wei_amount)])
    return result.stdout.strip()


def wei_to_hex(wei_amount):
    """Convert wei amount to hex."""
    result = run_command(["cast", "to-hex", str(wei_amount)])
    return result.stdout.strip()


# Add to exports
__all__ = [
    "run_command",
    "quiet_run_command",
    "get_function_info",
    "format_call_result",
    "CommandResult",
    "parse_sig",
    "decode_custom_error",
    "search_abi_for_error",
    "set_subprocess_runner",
    "reset_subprocess_runner",
    "ether_to_wei",
    "wei_to_ether",
    "wei_to_hex",
]
