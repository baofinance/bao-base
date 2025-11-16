// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentFoundryTestingOperator} from "@bao-test/deployment/DeploymentFoundryTestingOperator.sol";

/**
 * @title DeploymentOperatorTesting
 * @notice Generic testing mixin that auto-configures BaoDeployer operator
 * @dev Bridges production Deployment._requireBaoDeployerOperator() to the
 *      testing-only _setupBaoDeployerOperator() provided by
 *      DeploymentFoundryTestingOperator.
 *
 *      This keeps operator setup policy in bao-base and avoids concrete
 *      contracts (like DeploymentFoundryTesting) being used as bases in
 *      downstream systems.
 */
abstract contract DeploymentOperatorTesting is Deployment, DeploymentFoundryTestingOperator {
    /// @notice Override production assertion with auto-setup for testing
    /// @dev Uses _setupBaoDeployerOperator() from DeploymentFoundryTestingOperator
    function _requireBaoDeployerOperator() internal virtual override {
        _setupBaoDeployerOperator();
    }
}
