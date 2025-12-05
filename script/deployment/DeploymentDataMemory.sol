// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDeploymentData} from "./interfaces/IDeploymentData.sol";
import {DeploymentKeys, DataType} from "./DeploymentKeys.sol";

/**
 * @title DeploymentDataMemory
 * @notice In-memory data store for deployment state
 * @dev Extends DeploymentKeys to be its own key registry.
 *      Provides type-safe value storage plus deterministic JSON rendering.
 */
abstract contract DeploymentDataMemory is DeploymentKeys, IDeploymentData {
    error ValueNotSet(string key);
    error ReadTypeMismatch(string key, DataType expectedType, DataType actualType);

    struct TempNode {
        string name;
        uint256 parent;
        string valueJson;
        bool hasValue;
    }

    mapping(string => address) internal _addresses;
    mapping(string => string) internal _strings;
    mapping(string => uint256) internal _uints;
    mapping(string => int256) internal _ints;
    mapping(string => bool) internal _bools;

    mapping(string => address[]) internal _addressArrays;
    mapping(string => string[]) internal _stringArrays;
    mapping(string => uint256[]) internal _uintArrays;
    mapping(string => int256[]) internal _intArrays;

    mapping(string => bool) internal _hasKey;
    string[] internal _dataKeys;

    // ============ Scalar Getters ============

    function get(string memory key) external view virtual override returns (address value) {
        // Shorthand: contracts.Oracle → contracts.Oracle.address
        string memory addressKey = string.concat(key, ".address");
        _requireReadable(addressKey, DataType.ADDRESS);
        return _addresses[addressKey];
    }

    function getAddress(string memory key) external view virtual override returns (address value) {
        _requireReadable(key, DataType.ADDRESS);
        return _addresses[key];
    }

    function getString(string memory key) external view virtual override returns (string memory value) {
        _requireReadable(key, DataType.STRING);
        return _strings[key];
    }

    function getUint(string memory key) external view virtual override returns (uint256 value) {
        _requireReadable(key, DataType.UINT);
        return _uints[key];
    }

    function getInt(string memory key) external view virtual override returns (int256 value) {
        _requireReadable(key, DataType.INT);
        return _ints[key];
    }

    function getBool(string memory key) external view virtual override returns (bool value) {
        _requireReadable(key, DataType.BOOL);
        return _bools[key];
    }

    // ============ Array Getters ============

    function getAddressArray(string memory key) external view virtual override returns (address[] memory values) {
        _requireReadable(key, DataType.ADDRESS_ARRAY);
        return _addressArrays[key];
    }

    function getStringArray(string memory key) external view virtual override returns (string[] memory values) {
        _requireReadable(key, DataType.STRING_ARRAY);
        return _stringArrays[key];
    }

    function getUintArray(string memory key) external view virtual override returns (uint256[] memory values) {
        _requireReadable(key, DataType.UINT_ARRAY);
        return _uintArrays[key];
    }

    function getIntArray(string memory key) external view virtual override returns (int256[] memory values) {
        _requireReadable(key, DataType.INT_ARRAY);
        return _intArrays[key];
    }

    // ============ Introspection ============

    /// @notice Check if a key has a value set
    /// @dev For OBJECT type keys (contracts), checks if .address child is set (consistent with get() shorthand)
    /// TODO: Consider setting _hasKey[parentKey] = true when any child is written, which would
    /// eliminate the need for this OBJECT-specific check and make has() purely check _hasKey[key].
    function has(string memory key) external view virtual override returns (bool exists) {
        if (_hasKey[key]) {
            return true;
        }
        // For OBJECT type keys (contract entries), check if .address child is set
        // This mirrors get() which is a shorthand for getAddress(key + ".address")
        if (keyType(key) == DataType.OBJECT) {
            return _hasKey[string.concat(key, ".address")];
        }
        return false;
    }

    function keys() public view virtual override returns (string[] memory activeKeys) {
        // Count keys with values first
        uint256 count = 0;
        for (uint256 i = 0; i < _dataKeys.length; i++) {
            if (_hasKey[_dataKeys[i]]) {
                count++;
            }
        }

        // Collect keys with values
        activeKeys = new string[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _dataKeys.length; i++) {
            if (_hasKey[_dataKeys[i]]) {
                activeKeys[j++] = _dataKeys[i];
            }
        }
    }

    // ============ Shared Logic ============

    function _requireReadable(string memory key, DataType expected) private view {
        if (!_hasKey[key]) {
            revert ValueNotSet(key);
        }
        DataType actual = keyType(key);
        if (actual != expected) {
            revert ReadTypeMismatch(key, expected, actual);
        }
    }

    function _afterValueChanged(string memory key) internal virtual {}

    // ============ Internal Setters ============

    function _set(string memory key, address value) internal {
        string memory addressKey = string.concat(key, ".address");
        _prepareKey(addressKey, DataType.ADDRESS);
        _addresses[addressKey] = value;
        _afterValueChanged(key);
    }

    function _get(string memory key) internal view returns (address) {
        string memory addressKey = string.concat(key, ".address");
        _requireReadable(addressKey, DataType.ADDRESS);
        return _addresses[addressKey];
    }

    function _has(string memory key) internal view returns (bool) {
        if (_hasKey[key]) {
            return true;
        }
        if (keyType(key) == DataType.OBJECT) {
            return _hasKey[string.concat(key, ".address")];
        }
        return false;
    }

    function _setString(string memory key, string memory value) internal {
        _prepareKey(key, DataType.STRING);
        _strings[key] = value;
        _afterValueChanged(key);
    }

    function _getString(string memory key) internal view returns (string memory) {
        _requireReadable(key, DataType.STRING);
        return _strings[key];
    }

    function _setUint(string memory key, uint256 value) internal {
        _prepareKey(key, DataType.UINT);
        _uints[key] = value;
        _afterValueChanged(key);
    }

    function _getUint(string memory key) internal view returns (uint256) {
        _requireReadable(key, DataType.UINT);
        return _uints[key];
    }

    function _setInt(string memory key, int256 value) internal {
        _prepareKey(key, DataType.INT);
        _ints[key] = value;
        _afterValueChanged(key);
    }

    function _getInt(string memory key) internal view returns (int256) {
        _requireReadable(key, DataType.INT);
        return _ints[key];
    }

    function _setBool(string memory key, bool value) internal {
        _prepareKey(key, DataType.BOOL);
        _bools[key] = value;
        _afterValueChanged(key);
    }

    function _getBool(string memory key) internal view returns (bool) {
        _requireReadable(key, DataType.BOOL);
        return _bools[key];
    }

    function _setAddress(string memory key, address value) internal {
        _prepareKey(key, DataType.ADDRESS);
        _addresses[key] = value;
        _afterValueChanged(key);
    }

    function _getAddress(string memory key) internal view returns (address) {
        string memory lookup = key;
        if (keyType(key) == DataType.OBJECT) {
            lookup = string.concat(key, ".address");
        }

        _requireReadable(lookup, DataType.ADDRESS);
        return _addresses[lookup];
    }

    function _setAddressArray(string memory key, address[] memory values) internal {
        _prepareKey(key, DataType.ADDRESS_ARRAY);
        delete _addressArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _addressArrays[key].push(values[i]);
        }
        _afterValueChanged(key);
    }

    function _getAddressArray(string memory key) internal view returns (address[] memory) {
        _requireReadable(key, DataType.ADDRESS_ARRAY);
        return _addressArrays[key];
    }

    function _setStringArray(string memory key, string[] memory values) internal {
        _prepareKey(key, DataType.STRING_ARRAY);
        delete _stringArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _stringArrays[key].push(values[i]);
        }
        _afterValueChanged(key);
    }

    function _getStringArray(string memory key) internal view returns (string[] memory) {
        _requireReadable(key, DataType.STRING_ARRAY);
        return _stringArrays[key];
    }

    function _setUintArray(string memory key, uint256[] memory values) internal {
        _prepareKey(key, DataType.UINT_ARRAY);
        delete _uintArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _uintArrays[key].push(values[i]);
        }
        _afterValueChanged(key);
    }

    function _getUintArray(string memory key) internal view returns (uint256[] memory) {
        _requireReadable(key, DataType.UINT_ARRAY);
        return _uintArrays[key];
    }

    function _setIntArray(string memory key, int256[] memory values) internal {
        _prepareKey(key, DataType.INT_ARRAY);
        delete _intArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _intArrays[key].push(values[i]);
        }
        _afterValueChanged(key);
    }

    function _getIntArray(string memory key) internal view returns (int256[] memory) {
        _requireReadable(key, DataType.INT_ARRAY);
        return _intArrays[key];
    }

    function _prepareKey(string memory key, DataType expected) private {
        validateKey(key, expected);
        if (!_hasKey[key]) {
            _hasKey[key] = true;
            _dataKeys.push(key);
        }
    }
}
