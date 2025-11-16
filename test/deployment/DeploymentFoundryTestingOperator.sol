// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentRegistryJsonTesting} from "@bao-script/deployment/DeploymentRegistryJsonTesting.sol";
import {DeploymentFoundryTestingVm} from "@bao-script/deployment/DeploymentFoundryTestingVm.sol";
import {BaoDeployerSetOperator} from "@bao-script/deployment/BaoDeployerSetOperator.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

/**
 * @title DeploymentFoundryTestingOperator
 * @notice All-in-one testing mixin: results/ directory + VM + operator auto-setup
 * @dev Combines three testing mixins to provide testing infrastructure:
 *      - Testing directory configuration (results/, flat structure)
 *      - Foundry VM cheatcodes access
 *      - BaoDeployer operator auto-setup implementation
 *
 *      This mixin does NOT override _requireBaoDeployerOperator() to avoid diamond conflicts.
 *      Instead, it provides _setupBaoDeployerOperator() and impersonation hooks.
 *
 *      Concrete testing classes that extend Deployment should call _setupBaoDeployerOperator()
 *      in their override of _requireBaoDeployerOperator().
 *
 *      Usage:
 *        contract MyDeploymentTesting is MyDeployment, DeploymentFoundryTestingOperator {
 *            function _requireBaoDeployerOperator() internal virtual override {
 *                _setupBaoDeployerOperator();
 *            }
 *        }
 */
abstract contract DeploymentFoundryTestingOperator is
    DeploymentRegistryJsonTesting,
    DeploymentFoundryTestingVm,
    BaoDeployerSetOperator
{
    /**
     * @notice Start impersonating BaoDeployer multisig
     * @dev Uses VM.startPrank to impersonate BAOMULTISIG
     *      Required for setting operator on BaoDeployer contract
     */
    function _startBaoDeployerImpersonation()
        internal
        virtual
        override(BaoDeployerSetOperator, DeploymentFoundryTestingVm)
    {
        VM.startPrank(DeploymentInfrastructure.BAOMULTISIG);
    }

    /**
     * @notice Stop impersonating BaoDeployer multisig
     * @dev Uses VM.stopPrank to end impersonation
     */
    function _stopBaoDeployerImpersonation()
        internal
        virtual
        override(BaoDeployerSetOperator, DeploymentFoundryTestingVm)
    {
        VM.stopPrank();
    }
}
