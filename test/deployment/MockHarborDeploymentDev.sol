// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MockHarborDeploymentProduction} from "./MockHarborDeploymentProduction.sol";

/**
 * @title MockHarborDeploymentDev
 * @notice Development version of Harbor deployment
 * @dev Extends MockHarborDeploymentProduction with additional test keys
 *      All public API methods (setString, setAddress, etc.) come from DeploymentTesting
 *      which is already in the inheritance chain via MockHarborDeploymentProduction
 */
contract MockHarborDeploymentDev is MockHarborDeploymentProduction {
    // Additional keys for persistence testing
    string public constant PEGGED_CONFIG = "contracts.pegged.config";
    string public constant PEGGED_CONFIG_NAME = "contracts.pegged.config.name";

    constructor() {
        // Register persistence test keys
        addStringKey(PEGGED_CONFIG);
        addStringKey(PEGGED_CONFIG_NAME);
    }
}
