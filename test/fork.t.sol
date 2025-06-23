// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

contract TestFork is Test {
    function testMainnet() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);
    }
}
