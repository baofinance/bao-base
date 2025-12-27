// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";

/// @title DeploymentMemoryTesting
/// @notice Legacy alias providing a concrete DeploymentTesting harness
contract DeploymentMemoryTesting is DeploymentTesting {
    function _lookupContractPath(
        string memory /* contractType */,
        bytes memory /* creationCode */
    ) internal pure override returns (string memory path) {
        return "";
    }

    function _afterValueChanged(string memory key) internal virtual override {}

    function _save() internal virtual override {}

    function _beforeStart(
        string memory /* network */,
        string memory /* systemSaltString */,
        string memory /* startPoint */
    ) internal override {}

    function _afterValueChanged(string memory key) internal override {}

    function _save() internal override {}
}
