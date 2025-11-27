// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, console2} from "forge-std/Test.sol";

contract StdJsonKeyTest is Test {
    function testKeys() external pure {
        string memory addressJson = '{"contracts":{"pegged":"0x0000000000000000000000000000000000001234"}}';
        address parsed = vm.parseJsonAddress(addressJson, "$.contracts.pegged");
        console2.logAddress(parsed);

        string
            memory nestedJson = '{"contracts":{"pegged":{"implementation":"0x0000000000000000000000000000000000005678","symbol":"USD"}}}';
        address implementation = vm.parseJsonAddress(nestedJson, "$.contracts.pegged.implementation");
        console2.logAddress(implementation);
        string memory parsedSymbol = vm.parseJsonString(nestedJson, "$.contracts.pegged.symbol");
        console2.log(parsedSymbol);
    }
}
