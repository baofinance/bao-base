// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {SaltString} from "@bao-script/deployment/SaltString.sol";

/// @notice Tests SaltString — the single "::"-join salt-key builder.
contract SaltStringTest is BaoTest {
    function test_separatorIsDoubleColon() public pure {
        assertEq(SaltString.SEPARATOR, "::");
    }

    function test_key1_identity() public pure {
        assertEq(SaltString.key("pegged"), "pegged");
    }

    function test_key2_joinsTwoParts() public pure {
        assertEq(SaltString.key("ETH", "fxUSD"), "ETH::fxUSD");
    }

    function test_key3_joinsThreeParts() public pure {
        assertEq(SaltString.key("ETH", "fxUSD", "minter"), "ETH::fxUSD::minter");
    }

    function test_key4_joinsFourParts() public pure {
        assertEq(
            SaltString.key("ETH", "fxUSD", "stabilityPoolCollateral", "harvest"),
            "ETH::fxUSD::stabilityPoolCollateral::harvest"
        );
    }

    function test_key5_joinsFiveParts() public pure {
        assertEq(SaltString.key("a", "b", "c", "d", "e"), "a::b::c::d::e");
    }
}
