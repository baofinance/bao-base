// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentFoundryVm} from "@bao-script/deployment/DeploymentFoundryVm.sol";

/**
 * @title DeploymentFoundryTestingVm
 * @notice VM support mixin for Foundry test harnesses
 * @dev Provides startPrank/stopPrank implementations for test infrastructure
 *      Production deployments don't need this (they use real accounts)
 */
abstract contract DeploymentFoundryTestingVm is DeploymentFoundryVm {
    /**
     * @notice Start BaoDeployer impersonation for testing
     * @dev Override hook from BaoDeployerSetOperator
     */
    function _startBaoDeployerImpersonation() internal virtual {
        // Default no-op; override in concrete test harness with VM.startPrank()
    }

    /**
     * @notice Stop BaoDeployer impersonation for testing
     * @dev Override hook from BaoDeployerSetOperator
     */
    function _stopBaoDeployerImpersonation() internal virtual {
        // Default no-op; override in concrete test harness with VM.stopPrank()
    }
}
