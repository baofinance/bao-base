// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {DeploymentSnapLib} from "@bao-test/snap/DeploymentSnapLib.sol";

/// @title DumpSnap
/// @notice bin/snap's read: the network forked at a block, the listing's proxies under a prefix read there, and one line
/// a reading appended to a file, in the order read. bin/snap sorts them; it removes the file before the run.
contract DumpSnap is Script {
    function run(
        string memory fork,
        uint256 blockNumber,
        string memory listingPath,
        string memory prefix,
        address[] memory known,
        string memory outPath
    ) external {
        vm.createSelectFork(fork, blockNumber);
        DeploymentSnapLib.Reading[] memory readings = DeploymentSnapLib.read(vm.readFile(listingPath), prefix, known);
        for (uint256 i = 0; i < readings.length; ++i) {
            vm.writeLine(outPath, DeploymentSnapLib.line(readings[i]));
        }
    }
}
