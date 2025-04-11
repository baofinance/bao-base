import os
from unittest.mock import MagicMock, patch


from maul.resolution import (address_of, is_hex_address,
                             resolve_me_address)


def test_is_hex_address():
    # Valid address
    assert (
        is_hex_address("0x1234567890123456789012345678901234567890")
        == "0x1234567890123456789012345678901234567890"
    )

    # Invalid cases
    assert is_hex_address("not-an-address") is None
    assert is_hex_address("0x123") is None  # Too short
    assert is_hex_address(None) is None


def test_resolve_me_address():
    # With private key
    with patch.dict(os.environ, {"PRIVATE_KEY": "0xprivatekey"}), patch(
        "bin.maul.utils.run_command"
    ) as mock_run:
        mock_run.return_value = MagicMock(
            stdout="0x1234567890123456789012345678901234567890\n"
        )
        assert resolve_me_address() == "0x1234567890123456789012345678901234567890"

    # Without private key
    with patch.dict(os.environ, {}, clear=True):
        assert resolve_me_address() is None


def test_address_of():
    # Test the complete resolution flow with mocks for individual resolvers
    with patch(
        "maul.resolution.is_hex_address",
        side_effect=lambda x: x if x.startswith("0x") and len(x) == 42 else None,
    ), patch("maul.resolution.resolve_me_address", return_value="0xmeaddress"), patch(
        "maul.resolution.resolve_blockchain_address", return_value=None
    ), patch(
        "maul.resolution.resolve_deployment_log_address", return_value=None
    ):

        # Case 1: Already a hex address
        assert (
            address_of("any-network", "0x1234567890123456789012345678901234567890")
            == "0x1234567890123456789012345678901234567890"
        )

        # Case 2: Special 'me' case
        assert address_of("any-network", "me") == "0xmeaddress"

        # Case 3: Unresolvable name
        assert address_of("any-network", "unknown-contract") == "unknown-contract"
