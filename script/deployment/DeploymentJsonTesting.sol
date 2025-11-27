// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O
 * @dev Extends base Deployment with:
 *      - JSON file path resolution (input/output)
 *      - Timestamp-based file naming
 *      - DeploymentDataJson integration
 *      Subclasses implement _createDataLayer to choose specific JSON data implementation
 */
contract DeploymentJsonTesting is DeploymentJson, DeploymentTesting {
    // TODO: get rid of this by creating a base deployment with deployment memory derived from it
    function _createDeploymentData(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) internal virtual override(DeploymentJson, Deployment) returns (IDeploymentDataWritable data) {
        return DeploymentJson._createDeploymentData(network, systemSaltString, startPoint);
    }
}
