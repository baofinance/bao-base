// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {BaoDeployerSetOperator} from "@bao-script/deployment/BaoDeployerSetOperator.sol";

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
