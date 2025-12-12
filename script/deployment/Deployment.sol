// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

/**
 * @title Deployment
 * @notice Production deployment with default BaoFactory (production bytecode)
 * @dev Extends DeploymentBase with production default for _ensureBaoFactory().
 *
 *      Use this when:
 *      - You want production BaoFactory bytecode
 *      - You don't need mixin flexibility
 *
 *      For specialized behavior (e.g., tests), extend DeploymentBase directly and
 *      mix in `DeploymentTesting` or provide a custom `_ensureBaoFactory()` override.
 */
abstract contract Deployment is DeploymentBase {
    /// @notice Ensure BaoFactory is deployed using production bytecode
    /// @dev This is the production default - uses captured bytecode
    function _ensureBaoFactory() internal virtual override returns (address factory) {
        factory = DeploymentInfrastructure._ensureBaoFactoryProduction();
    }
}
