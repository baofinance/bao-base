// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeploymentKeys} from "./DeploymentKeys.sol";
import {DeploymentDataStore} from "./DeploymentDataStore.sol";

/**
 * @title DeploymentDataMemory
 * @notice Thin wrapper over DeploymentDataStore for pure in-memory usage
 */
contract DeploymentDataMemory is DeploymentDataStore {
    constructor(DeploymentKeys keyRegistry) DeploymentDataStore(keyRegistry) {}
}
