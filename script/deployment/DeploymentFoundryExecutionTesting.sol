// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentOperatorTesting} from "./DeploymentOperatorTesting.sol";
import {DeploymentRegistryJsonTesting} from "./DeploymentRegistryJsonTesting.sol";

/**
 * @title DeploymentFoundryExecutionTesting
 * @notice Testing conduit that layers operator automation plus Foundry utilities.
 * @dev Inherits DeploymentOperatorTesting (which carries the Deployment
 *      overrides needed for BaoDeployer operator auto-setup) and the
 *      test-specific JSON mixin. Keeps directory behavior centralized in
 *      DeploymentRegistryJsonTesting (results/ root, flat structure).
 */
abstract contract DeploymentFoundryExecutionTesting is DeploymentRegistryJsonTesting, DeploymentOperatorTesting {}
