// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

/**
 * @title BaoDeployerSetOperator
 * @notice Test-only mixin that ensures BaoDeployer operator is configured for the harness
 * @dev Callers must supply an impersonation mechanism via _startBaoDeployerImpersonation/_stopBaoDeployerImpersonation
 */
abstract contract BaoDeployerSetOperator {
    function _ensureBaoDeployerOperatorConfigured() internal {
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
