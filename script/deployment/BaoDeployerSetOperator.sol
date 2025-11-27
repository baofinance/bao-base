// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title BaoDeployerSetOperator
 * @notice Test-only mixin that auto-configures BaoDeployer operator for the harness
 * @dev Provides _setUpBaoDeployerOperator() to automatically set operator via VM.prank
 *      Callers must supply impersonation mechanism via _startBaoDeployerImpersonation/_stopBaoDeployerImpersonation
 */
abstract contract BaoDeployerSetOperator {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Auto-configure BaoDeployer operator if not already set
    /// @dev Uses impersonation to call setOperator() - testing only
    ///      Production code uses _requireBaoDeployerOperator() which asserts instead
    function _setUpBaoDeployerOperator() internal {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (baoDeployer.code.length > 0 && BaoDeployer(baoDeployer).operator() != address(this)) {
            VM.startPrank(DeploymentInfrastructure.BAOMULTISIG);
            BaoDeployer(baoDeployer).setOperator(address(this));
            VM.stopPrank();
        }
    }
}
