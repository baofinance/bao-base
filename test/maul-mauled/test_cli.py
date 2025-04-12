from unittest.mock import patch

import pytest

# Import directly from the implementation module
from bin.maul.utils import parse_sig


def test_sig_command():
    """Test the signature parsing functionality directly."""
    result = parse_sig("ERC20.transfer")
    assert result["signature"] == "transfer(address,uint256)"
    assert result["contract"] == "ERC20"
    # Additional assertions...
