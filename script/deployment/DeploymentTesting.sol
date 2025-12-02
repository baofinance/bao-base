// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTestingEnablers} from "@bao-script/deployment/DeploymentTestingEnablers.sol";
import {BaoDeployerSetOperator} from "@bao-script/deployment/BaoDeployerSetOperator.sol";

/**
 * @title DeploymentTesting
 * @notice test-specific deployment
 * @dev Extends base Deployment with:
 *      - access to the underlying data structure for testing
 *      - auto-configuration of BaoDeployer operator for testing
 *      - automatic stub deployment
 */
abstract contract DeploymentTesting is DeploymentTestingEnablers, BaoDeployerSetOperator {
    /// @notice Start deployment session with deployer defaulting to address(this)
    /// @dev Convenience overload for tests where the harness is the deployer
    function start(string memory network, string memory systemSaltString, string memory startPoint) public {
        start(network, systemSaltString, address(this), startPoint);
    }

    /// @notice Simulate predictable deploy without providing the required value (for testing underfunding scenarios)
    /// @dev This commits but calls reveal with value=0, triggering ValueMismatch error
    ///      contractType and contractPath parameters kept for API compatibility but unused
    /// @param value The value required for deployment
    /// @param key The contract key
    /// @param initCode The contract creation bytecode
    /// @return addr The predicted address (will revert before returning)
    function simulatePredictableDeployWithoutFunding(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory /* contractType */,
        string memory /* contractPath */
    ) external virtual returns (address addr) {
        return _simulatePredictableDeployWithoutFundingInternal(value, key, initCode);
    }

    // ============================================================================
    // Hook Implementation - No-op for memory-only testing
    // ============================================================================

    function _afterValueChanged(string memory /* key */) internal virtual override {
        // No persistence needed for memory-only testing
    }

    // ============================================================================
    // Convenience Methods
    // ============================================================================

    /// @notice Set contract address (key.address) - convenience for tests
    function setContractAddress(string memory key, address value) public {
        _set(key, value);
    }
}
