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
    /// @dev Adds "contracts." prefix: "pegged" → "contracts.pegged"
    function set(string memory key, address value) public {
        _set(key, value);
    }

    /// @notice Get contract address
    /// @dev Adds "contracts." prefix: "pegged" → "contracts.pegged"
    function get(string memory key) public view returns (address) {
        return _get(key);
    }

    /// @notice Check if contract key exists
    /// @dev Adds "contracts." prefix
    function has(string memory key) public view returns (bool) {
        return _has(key);
    }

    /// @notice Set string value
    /// @dev Adds "contracts." prefix: "pegged.symbol" → "contracts.pegged.symbol"
    function setString(string memory key, string memory value) public {
        _setString(key, value);
    }

    /// @notice Get string value
    /// @dev Adds "contracts." prefix
    function getString(string memory key) public view returns (string memory) {
        return _getString(key);
    }

    /// @notice Set uint value
    /// @dev Adds "contracts." prefix
    function setUint(string memory key, uint256 value) public {
        _setUint(key, value);
    }

    /// @notice Get uint value
    /// @dev Adds "contracts." prefix
    function getUint(string memory key) public view returns (uint256) {
        return _getUint(key);
    }

    /// @notice Set int value
    /// @dev Adds "contracts." prefix
    function setInt(string memory key, int256 value) public {
        _setInt(key, value);
    }

    /// @notice Get int value
    /// @dev Adds "contracts." prefix
    function getInt(string memory key) public view returns (int256) {
        return _getInt(key);
    }

    /// @notice Set bool value
    /// @dev Adds "contracts." prefix
    function setBool(string memory key, bool value) public {
        _setBool(key, value);
    }

    /// @notice Get bool value
    /// @dev Adds "contracts." prefix
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
    /// @dev Adds "contracts." prefix
    function setAddressArray(string memory key, address[] memory values) public {
        _setAddressArray(key, values);
    }

    /// @notice Get address array
    /// @dev Adds "contracts." prefix
    function getAddressArray(string memory key) public view returns (address[] memory) {
        return _getAddressArray(key);
    }

    /// @notice Set string array
    /// @dev Adds "contracts." prefix
    function setStringArray(string memory key, string[] memory values) public {
        _setStringArray(key, values);
    }

    /// @notice Get string array
    /// @dev Adds "contracts." prefix
    function getStringArray(string memory key) public view returns (string[] memory) {
        return _getStringArray(key);
    }

    /// @notice Set uint array
    /// @dev Adds "contracts." prefix
    function setUintArray(string memory key, uint256[] memory values) public {
        _setUintArray(key, values);
    }

    /// @notice Get uint array
    /// @dev Adds "contracts." prefix
    function getUintArray(string memory key) public view returns (uint256[] memory) {
        return _getUintArray(key);
    }

    /// @notice Set int array
    /// @dev Adds "contracts." prefix
    function setIntArray(string memory key, int256[] memory values) public {
        _setIntArray(key, values);
    }

    /// @notice Get int array
    /// @dev Adds "contracts." prefix
    function getIntArray(string memory key) public view returns (int256[] memory) {
        return _getIntArray(key);
    }
}
