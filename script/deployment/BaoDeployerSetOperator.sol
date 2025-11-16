// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

/**
 * @title BaoDeployerSetOperator
 * @notice Test-only mixin that auto-configures BaoDeployer operator for the harness
 * @dev Provides _setupBaoDeployerOperator() to automatically set operator via VM.prank
 *      Callers must supply impersonation mechanism via _startBaoDeployerImpersonation/_stopBaoDeployerImpersonation
 */
abstract contract BaoDeployerSetOperator {
    /// @notice Auto-configure BaoDeployer operator if not already set
    /// @dev Uses impersonation to call setOperator() - testing only
    ///      Production code uses _requireBaoDeployerOperator() which asserts instead
    function _setupBaoDeployerOperator() internal {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (baoDeployer.code.length > 0 && BaoDeployer(baoDeployer).operator() != address(this)) {
            _startBaoDeployerImpersonation();
            BaoDeployer(baoDeployer).setOperator(address(this));
            _stopBaoDeployerImpersonation();
        }
    }

    function _startBaoDeployerImpersonation() internal virtual;

    function _stopBaoDeployerImpersonation() internal virtual;
}
