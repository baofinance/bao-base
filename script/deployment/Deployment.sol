// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";

/**
 * @title Deployment
 * @notice Production deployment requiring pre-deployed BaoFactory
 * @dev Extends DeploymentBase with production default for _ensureBaoFactory().
 *
 *      Use this when:
 *      - BaoFactory is already deployed and upgraded to v1
 *      - You don't need mixin flexibility
 *
 *      For specialized behavior (e.g., tests), extend DeploymentBase directly and
 *      mix in `DeploymentTesting` or provide a custom `_ensureBaoFactory()` override.
 *
 *      Production assumes infrastructure is in place - reverts if not functional.
 */
abstract contract Deployment is DeploymentBase {
    /// @notice Require BaoFactory is deployed and functional
    /// @dev Reverts if BaoFactory is not deployed or not upgraded to v1
    // function _ensureBaoFactory() internal virtual override returns (address factory) {
    //     BaoFactoryDeployment.requireFunctionalBaoFactory();
    //     factory = BaoFactoryDeployment.predictBaoFactoryAddress();
    // }
}
