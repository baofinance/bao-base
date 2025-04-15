import re
import sys

from mauled.eth.error import decode_custom_error


def ethereum_error_handler(result, sig_input=None):
    """
    Custom error handler for Ethereum commands that can decode custom errors.

    Args:
        result: Command execution result containing stdout, stderr, and args
        sig_input: Optional signature input for decoding errors
    """
    logger.info(f"Command failed: {' '.join(result.args)}")

    if result.stderr:
        error_msg = result.stderr.strip()

        # Look for custom error pattern in the error message
        custom_error_match = None
        if "custom error" in error_msg:
            custom_error_match = re.search(r'custom error ([^,\s]+)(?:, data: "([^"]+)")?', error_msg)

        if custom_error_match:
            error_selector = custom_error_match.group(1)
            error_data = custom_error_match.group(2) if custom_error_match.group(2) else error_selector

            # Decode the error
            decoded_error, raw_data = decode_custom_error(error_data, sig_input=sig_input)
            logger.info(f"{decoded_error}")
            logger.info(f"Raw error data: {raw_data}")
        else:
            logger.info(f"Error: {error_msg}")

    if result.stdout:
        logger.info(f"Output: {result.stdout.strip()}")

    logger.info(f"Exit code: {result.returncode}")
    sys.exit(result.returncode)
