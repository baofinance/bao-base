// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {BaoDeployerSetOperator} from "@bao-script/deployment/BaoDeployerSetOperator.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

/**
 * @title DeploymentTesting
 * @notice test-specific deployment
 * @dev Extends base Deployment with:
 *      - access to the underlying data structure for testing
 *      - auto-configuration of BaoDeployer operator for testing
 */
abstract contract DeploymentTesting is Deployment, BaoDeployerSetOperator {
    function _ensureBaoDeployerOperator() internal override {
        _setUpBaoDeployerOperator();
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
        _requireActiveRun();
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_has(key)) {
            revert(); // ContractAlreadyExists - would need to import the error
        }

        bytes32 salt = EfficientHashLib.hash(abi.encodePacked(_getString(SYSTEM_SALT_STRING), "/", key, "/contract"));
        address baoDeployerAddr = DeploymentInfrastructure.predictBaoDeployerAddress();
        BaoDeployer baoDeployer = BaoDeployer(baoDeployerAddr);
        bytes32 commitment = DeploymentInfrastructure.commitment(address(this), value, salt, keccak256(initCode));
        baoDeployer.commit(commitment);

        // Call reveal with value=0 instead of the required value - this will trigger ValueMismatch
        addr = baoDeployer.reveal{value: 0}(initCode, salt, value);
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
