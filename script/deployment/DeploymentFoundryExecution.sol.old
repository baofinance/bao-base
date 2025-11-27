// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentRegistryJson} from "./DeploymentRegistryJson.sol";

/**
 * @title DeploymentFoundryExecution
 * @notice Production-focused mixin that layers Foundry JSON persistence utilities.
 * @dev Designed to be combined with core Deployment-derived contracts without
 *      introducing an additional Deployment inheritance path. Keeps Foundry VM
 *      helpers and JSON persistence colocated while letting downstream systems
 *      decide how to compose execution + domain logic.
 */
abstract contract DeploymentFoundryExecution is DeploymentRegistryJson {}
