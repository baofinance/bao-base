// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentRegistryJson} from "./DeploymentRegistryJson.sol";

/**
 * @title DeploymentRegistryJsonTesting
 * @notice JSON persistence mixin for test suites with results/ directory
 * @dev Extends DeploymentRegistryJson with test-specific directory configuration
 *      - Writes to results/ instead of ./ (configurable via BAO_DEPLOYMENT_LOGS_ROOT)
 *      - Uses flat structure (no network subdirectories)
 */
abstract contract DeploymentRegistryJsonTesting is DeploymentRegistryJson {
    /**
     * @notice Override to use results/ base directory for test files
     * @dev Can be overridden via BAO_DEPLOYMENT_LOGS_ROOT environment variable
     * @return Base directory path - "results" for test suites
     */
    function _getBaseDirPrefix() internal view override returns (string memory) {
        if (VM.envExists("BAO_DEPLOYMENT_LOGS_ROOT")) {
            return VM.envString("BAO_DEPLOYMENT_LOGS_ROOT");
        }
        return "results";
    }

    /**
     * @notice Override to use flat structure (no network subdirectories) in tests
     * @return false - tests use flat directory structure
     */
    function _useNetworkSubdir() internal pure override returns (bool) {
        return false;
    }
}
