// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O
 * @dev Extends base Deployment with test accessor functions
 */
contract DeploymentJsonTesting is DeploymentJson, DeploymentTesting {
    DeploymentDataJsonTesting _dataJson;

    // TODO: get rid of this by creating a base deployment with deployment memory derived from it
    // TODO: factorize this as it's a copy of the super contract
    function _createDeploymentData(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) internal virtual override(DeploymentJson, Deployment) returns (IDeploymentDataWritable data) {
        string memory inputPath = _resolveInputPath(network, systemSaltString, startPoint);
        string memory outputPath = _buildOutputPath(network, systemSaltString);
        _dataJson = new DeploymentDataJsonTesting(this, inputPath);
        _dataJson.setOutputPath(outputPath);
        return _dataJson;
    }

    function toJson() public returns (string memory) {
        return _dataJson.toJson();
    }

    function fromJson(string memory json) public {
        _dataJson.fromJson(json);
    }
}
