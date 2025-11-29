// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDeploymentDataWritable} from "./interfaces/IDeploymentDataWritable.sol";
import {DeploymentKeys, DataType} from "./DeploymentKeys.sol";

/**
 * @title DeploymentDataStore
 * @notice Canonical in-memory data store shared by all deployment data layers
 * @dev Provides type-safe value storage plus deterministic JSON rendering
 */
contract DeploymentDataMemory is IDeploymentDataWritable {
    error ValueNotSet(string key);
    error ReadTypeMismatch(string key, DataType expectedType, DataType actualType);

    struct TempNode {
        string name;
        uint256 parent;
        string valueJson;
        bool hasValue;
    }

    DeploymentKeys internal immutable _deploymentKeys;

    mapping(string => address) internal _addresses;
    mapping(string => string) internal _strings;
    mapping(string => uint256) internal _uints;
    mapping(string => int256) internal _ints;
    mapping(string => bool) internal _bools;

    mapping(string => address[]) internal _addressArrays;
    mapping(string => string[]) internal _stringArrays;
    mapping(string => uint256[]) internal _uintArrays;
    mapping(string => int256[]) internal _intArrays;

    mapping(string => DataType) internal _types;
    mapping(string => bool) internal _hasKey;
    string[] internal _allKeys;

    constructor(DeploymentKeys keyRegistry) {
        _deploymentKeys = keyRegistry;
    }

    // ============ Scalar Getters ============

    function get(string memory key) external view override returns (address value) {
        _requireReadable(key, DataType.CONTRACT);
        return _addresses[key];
    }

    function getAddress(string memory key) external view override returns (address value) {
        _requireReadable(key, DataType.ADDRESS);
        return _addresses[key];
    }

    function getString(string memory key) external view override returns (string memory value) {
        _requireReadable(key, DataType.STRING);
        return _strings[key];
    }

    function getUint(string memory key) external view override returns (uint256 value) {
        _requireReadable(key, DataType.UINT);
        return _uints[key];
    }

    function getInt(string memory key) external view override returns (int256 value) {
        _requireReadable(key, DataType.INT);
        return _ints[key];
    }

    function getBool(string memory key) external view override returns (bool value) {
        _requireReadable(key, DataType.BOOL);
        return _bools[key];
    }

    // ============ Array Getters ============

    function getAddressArray(string memory key) external view override returns (address[] memory values) {
        _requireReadable(key, DataType.ADDRESS_ARRAY);
        return _addressArrays[key];
    }

    function getStringArray(string memory key) external view override returns (string[] memory values) {
        _requireReadable(key, DataType.STRING_ARRAY);
        return _stringArrays[key];
    }

    function getUintArray(string memory key) external view override returns (uint256[] memory values) {
        _requireReadable(key, DataType.UINT_ARRAY);
        return _uintArrays[key];
    }

    function getIntArray(string memory key) external view override returns (int256[] memory values) {
        _requireReadable(key, DataType.INT_ARRAY);
        return _intArrays[key];
    }

    // ============ Introspection ============

    function has(string memory key) external view override returns (bool exists) {
        return _hasKey[key];
    }

    function keys() external view override returns (string[] memory allKeys) {
        return _allKeys;
    }

    // ============ Scalar Setters ============

    function set(string memory key, address value) external override {
        _writeAddress(key, value, DataType.CONTRACT);
    }

    function setAddress(string memory key, address value) external override {
        _writeAddress(key, value, DataType.ADDRESS);
    }

    function setString(string memory key, string memory value) external override {
        _writeString(key, value, DataType.STRING);
    }

    function setUint(string memory key, uint256 value) external override {
        _writeUint(key, value, DataType.UINT);
    }

    function setInt(string memory key, int256 value) external override {
        _writeInt(key, value, DataType.INT);
    }

    function setBool(string memory key, bool value) external override {
        _writeBool(key, value, DataType.BOOL);
    }

    // ============ Array Setters ============

    function setAddressArray(string memory key, address[] memory values) external override {
        _writeAddressArray(key, values, DataType.ADDRESS_ARRAY);
    }

    function setStringArray(string memory key, string[] memory values) external override {
        _writeStringArray(key, values, DataType.STRING_ARRAY);
    }

    function setUintArray(string memory key, uint256[] memory values) external override {
        _writeUintArray(key, values, DataType.UINT_ARRAY);
    }

    function setIntArray(string memory key, int256[] memory values) external override {
        _writeIntArray(key, values, DataType.INT_ARRAY);
    }

    // ============ Hook ============

    // ============ Shared Logic ============

    function _requireReadable(string memory key, DataType expected) private view {
        if (!_hasKey[key]) {
            revert ValueNotSet(key);
        }
        if (_types[key] != expected) {
            revert ReadTypeMismatch(key, expected, _types[key]);
        }
    }

    function _writeAddress(string memory key, address value, DataType expected) internal {
        _prepareKey(key, expected);
        _addresses[key] = value;
    }

    function _writeString(string memory key, string memory value, DataType expected) internal {
        _prepareKey(key, expected);
        _strings[key] = value;
    }

    function _writeUint(string memory key, uint256 value, DataType expected) internal {
        _prepareKey(key, expected);
        _uints[key] = value;
    }

    function _writeInt(string memory key, int256 value, DataType expected) internal {
        _prepareKey(key, expected);
        _ints[key] = value;
    }

    function _writeBool(string memory key, bool value, DataType expected) internal {
        _prepareKey(key, expected);
        _bools[key] = value;
    }

    function _writeAddressArray(string memory key, address[] memory values, DataType expected) internal {
        _prepareKey(key, expected);
        delete _addressArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _addressArrays[key].push(values[i]);
        }
    }

    function _writeStringArray(string memory key, string[] memory values, DataType expected) internal {
        _prepareKey(key, expected);
        delete _stringArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _stringArrays[key].push(values[i]);
        }
    }

    function _writeUintArray(string memory key, uint256[] memory values, DataType expected) internal {
        _prepareKey(key, expected);
        delete _uintArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _uintArrays[key].push(values[i]);
        }
    }

    function _writeIntArray(string memory key, int256[] memory values, DataType expected) internal {
        _prepareKey(key, expected);
        delete _intArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _intArrays[key].push(values[i]);
        }
    }

    function _prepareKey(string memory key, DataType expected) private {
        _deploymentKeys.validateKey(key, expected);
        if (!_hasKey[key]) {
            _hasKey[key] = true;
            _allKeys.push(key);
        }
        _types[key] = expected;
    }
}
