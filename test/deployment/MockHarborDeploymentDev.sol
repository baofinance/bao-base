// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MockHarborDeploymentProduction} from "./MockHarborDeploymentProduction.sol";

/**
 * @title MockHarborDeploymentDev
 * @notice Development version of Harbor deployment
 * @dev Just an alias for MockHarborDeploymentProduction
 *      All public API methods (setString, setAddress, etc.) come from DeploymentTesting
 *      which is already in the inheritance chain via MockHarborDeploymentProduction
 */
contract MockHarborDeploymentDev is MockHarborDeploymentProduction {
    // No additional code needed!
    // - deployPegged() inherited from MockHarborDeploymentProduction
    // - setString/setAddress/etc. inherited from DeploymentTesting (via MockHarborDeploymentProduction)
    // - _createDataLayer() inherited from MockHarborDeploymentProduction
    // - All test configuration inherited from DeploymentTesting
}
