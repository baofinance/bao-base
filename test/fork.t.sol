// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";

/// @notice A fork of mainnet is taken through BaoTest at the default block the list names.
contract TestFork is BaoTest {
    function testMainnet() public {
        createSelectFork("mainnet");
        assertEq(block.number, listedBlock(FORK_DEFAULT));
    }
}
