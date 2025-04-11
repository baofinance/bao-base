"""Formatting utilities for MAUL."""

def format_call_result(stdout, sig_input=None, network=None):
    """Format call result based on output content and expected return type."""
    # Special handling for test mocks
    if hasattr(stdout, 'stdout') and stdout.stdout:
        # Handle the case where we're passed a CompletedProcess or MagicMock
        result = stdout.stdout.strip() if hasattr(stdout.stdout, 'strip') else stdout.stdout
    else:
        # Normal string processing
        result = stdout.strip() if hasattr(stdout, 'strip') else stdout

    if not result:
        return "No result"

    if isinstance(result, str) and "\n" in result:
        return f"\n{result}"

    return result

def parse_sig(network, sig_input):
    """
    Parse a signature input which can be either a full function signature
    or a contract.function format.

    Args:
        network: Network name
        sig_input: Function signature string
S
    Returns:
        tuple: (signature_string, param_types)
    """
    if "(" in sig_input:
        # Full function signature
        func_name = sig_input[:sig_input.find("(")]
        param_str = sig_input[sig_input.find("(")+1:sig_input.find(")")]
        param_types = param_str.split(",") if param_str else []
        return sig_input, param_types
    elif "." in sig_input:
        # contract.function format
        contract, func_name = sig_input.split(".", 1)
        # Simplified for now
        return f"{func_name}()", []
    else:
        raise ValueError(f"Invalid signature format: {sig_input}")
