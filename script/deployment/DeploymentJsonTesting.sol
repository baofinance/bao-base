// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";

import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentJsonTesting
 * @notice JSON deployment layer extended for test environments
 * @dev Combines DeploymentJson (JSON persistence) with DeploymentTesting (test BaoFactory).
 *
 * Inherits:
 * - DeploymentJson: Full JSON persistence with setter hooks
 * - DeploymentTesting: Current build bytecode + operator setup for BaoFactory
 *
 * Provides:
 * - Test output directory (BAO_DEPLOYMENT_LOGS_ROOT or "results")
 * - Filename override for custom output paths
 * - Automatic/manual sequencing for capturing deployment phases
 */
contract DeploymentJsonTesting is DeploymentJson, DeploymentTesting {
    // ============================================================================
    // Test Output Configuration
    // ============================================================================

    constructor() DeploymentJson(block.timestamp) {}

    function _getPrefix() internal view override returns (string memory) {
        return DeploymentTestingOutput._getPrefix();
    }

    function _saveLatestLogToo() internal pure override returns (bool) {
        return false;
    }

    /// @dev Resolve _afterValueChanged - use DeploymentJson's implementation for JSON persistence
    function _afterValueChanged(string memory key) internal virtual override(DeploymentDataMemory, DeploymentJson) {
        DeploymentJson._afterValueChanged(key);
    }
}

library DeploymentTestingOutput {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _getPrefix() internal view returns (string memory) {
        try VM.envString("BAO_DEPLOYMENT_LOGS_ROOT") returns (string memory customRoot) {
            if (bytes(customRoot).length > 0) {
                return customRoot;
            }
        } catch {
            // Environment variable not set, use default
        }
        return "results";
    }
}
