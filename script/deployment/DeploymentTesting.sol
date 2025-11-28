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
contract DeploymentTesting is Deployment, BaoDeployerSetOperator {
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
    // access to keyed data
    // ============================================================================

    /// @notice Set contract address
    function set(string memory key, address value) public {
        _set(key, value);
    }

    /// @notice Get contract address
    function get(string memory key) public view returns (address) {
        return _get(key);
    }

    /// @notice Check if contract key exists
    function has(string memory key) public view returns (bool) {
        return _has(key);
    }

    /// @notice Set string value
    function setString(string memory key, string memory value) public {
        _setString(key, value);
    }

    /// @notice Get string value
    function getString(string memory key) public view returns (string memory) {
        return _getString(key);
    }

    /// @notice Set uint value
    function setUint(string memory key, uint256 value) public {
        _setUint(key, value);
    }

    /// @notice Get uint value
    function getUint(string memory key) public view returns (uint256) {
        return _getUint(key);
    }

    /// @notice Set int value
    function setInt(string memory key, int256 value) public {
        _setInt(key, value);
    }

    /// @notice Get int value
    function getInt(string memory key) public view returns (int256) {
        return _getInt(key);
    }

    /// @notice Set bool value
    function setBool(string memory key, bool value) public {
        _setBool(key, value);
    }

    /// @notice Get bool value
    function getBool(string memory key) public view returns (bool) {
        return _getBool(key);
    }

    function setAddress(string memory key, address value) public {
        _setAddress(key, value);
    }

    function getAddress(string memory key) public view returns (address) {
        return _getAddress(key);
    }

    /// @notice Set address array
    function setAddressArray(string memory key, address[] memory values) public {
        _setAddressArray(key, values);
    }

    /// @notice Get address array
    function getAddressArray(string memory key) public view returns (address[] memory) {
        return _getAddressArray(key);
    }

    /// @notice Set string array
    function setStringArray(string memory key, string[] memory values) public {
        _setStringArray(key, values);
    }

    /// @notice Get string array
    function getStringArray(string memory key) public view returns (string[] memory) {
        return _getStringArray(key);
    }

    /// @notice Set uint array
    function setUintArray(string memory key, uint256[] memory values) public {
        _setUintArray(key, values);
    }

    /// @notice Get uint array
    function getUintArray(string memory key) public view returns (uint256[] memory) {
        return _getUintArray(key);
    }

    /// @notice Set int array
    function setIntArray(string memory key, int256[] memory values) public {
        _setIntArray(key, values);
    }

    /// @notice Get int array
    function getIntArray(string memory key) public view returns (int256[] memory) {
        return _getIntArray(key);
    }
}
