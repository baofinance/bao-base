"""Unit tests for maul utility functions."""

from unittest.mock import MagicMock, patch

import pytest

# Import directly from the implementation module
from bin.maul.utils import decode_custom_error, format_call_result, parse_sig


def test_parse_sig():
    """Test signature parsing functionality comprehensively."""
    # Test with Contract.function format
    with patch("bin.maul.core.contracts.get_contract_abi") as mock_get_abi:
        # Mock the contract ABI
        mock_get_abi.return_value = [
            {
                "name": "transfer",
                "type": "function",
                "inputs": [
                    {"name": "recipient", "type": "address"},
                    {"name": "amount", "type": "uint256"},
                ],
                "outputs": [{"name": "success", "type": "bool"}],
            },
            {
                "name": "balanceOf",
                "type": "function",
                "inputs": [{"name": "account", "type": "address"}],
                "outputs": [{"name": "balance", "type": "uint256"}],
            },
            {
                "name": "complexFunction",
                "type": "function",
                "inputs": [
                    {"name": "user", "type": "address"},
                    {"name": "values", "type": "uint256[]"},
                    {"name": "active", "type": "bool"},
                ],
                "outputs": [
                    {"name": "success", "type": "bool"},
                    {"name": "data", "type": "bytes"},
                ],
            },
            {
                "name": "noParamFunc",
                "type": "function",
                "inputs": [],
                "outputs": [{"name": "version", "type": "string"}],
            },
        ]

        # Test basic Contract.function format
        result = parse_sig("ERC20.transfer")
        assert result["signature"] == "transfer(address,uint256)"
        assert result["contract"] == "ERC20"
        assert result["function"] == "transfer"
        assert len(result["inputs"]) == 2
        assert result["inputs"][0]["type"] == "address"
        assert result["inputs"][1]["type"] == "uint256"
        assert len(result["outputs"]) == 1
        assert result["outputs"][0]["type"] == "bool"

        # Test function with single param
        result = parse_sig("ERC20.balanceOf")
        assert result["signature"] == "balanceOf(address)"
        assert len(result["inputs"]) == 1
        assert result["inputs"][0]["name"] == "account"

        # Test function with complex params and multiple return values
        result = parse_sig("ERC20.complexFunction")
        assert result["signature"] == "complexFunction(address,uint256[],bool)"
        assert len(result["inputs"]) == 3
        assert result["inputs"][1]["type"] == "uint256[]"
        assert len(result["outputs"]) == 2
        assert result["outputs"][1]["type"] == "bytes"

        # Test function with no params
        result = parse_sig("ERC20.noParamFunc")
        assert result["signature"] == "noParamFunc()"
        assert len(result["inputs"]) == 0
        assert result["outputs"][0]["type"] == "string"

    # Test direct signature format without ABI lookup
    result = parse_sig("approve(address,uint256)")
    assert result["signature"] == "approve(address,uint256)"
    assert result["function"] == "approve"
    assert "contract" not in result or not result["contract"]
    assert len(result["inputs"]) == 2
    assert result["inputs"][0]["type"] == "address"

    # Test direct signature with no parameters
    result = parse_sig("version()")
    assert result["signature"] == "version()"
    assert result["function"] == "version"
    assert len(result["inputs"]) == 0

    # Test direct signature with array type
    result = parse_sig("setItems(uint256[])")
    assert result["signature"] == "setItems(uint256[])"
    assert result["inputs"][0]["type"] == "uint256[]"

    # Test invalid signature format
    with pytest.raises(ValueError):
        parse_sig("invalid_signature")
