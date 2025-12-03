// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";

/// @title DeploymentMemoryTesting
/// @notice Legacy alias providing a concrete DeploymentTesting harness
contract DeploymentMemoryTesting is DeploymentTesting {
    function _lookupContractPath(string memory /* contractType */) internal pure override returns (string memory path) {
        return "";
    }
}
