// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeploymentDataJson} from "./DeploymentDataJson.sol";
import {DeploymentKeys} from "./DeploymentKeys.sol";

/**
 * @title DeploymentDataJsonTesting
 * @notice Testing variant with optional sequence numbering for tracking update progression
 * @dev Call enableSequencing() to add .001, .002, .003 suffixes on subsequent writes
 *      By default, overwrites the same file like production deployments
 */
contract DeploymentDataJsonTesting is DeploymentDataJson {
    string private _baseOutputPath; // Path without sequence suffix

    constructor(DeploymentKeys keyRegistry) DeploymentDataJson(keyRegistry) {}

}
