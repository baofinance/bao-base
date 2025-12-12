// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {IDeploymentData} from "./interfaces/IDeploymentData.sol";
import {DeploymentKeys, DataType} from "./DeploymentKeys.sol";
import {Array} from "@bao-script/utils/Array.sol";

/**
 * @title DeploymentDataMemory
 * @notice In-memory data store for deployment state
 * @dev Extends DeploymentKeys to be its own key registry.
 *      Provides type-safe value storage plus deterministic JSON rendering.
 */
abstract contract DeploymentDataMemory is DeploymentKeys, IDeploymentData, Array {
    using LibString for string;

    error ValueNotSet(string key);
    error ReadTypeMismatch(string key, DataType expectedType, DataType actualType);
    error InvalidHexAddress(string value);

    /// @notice Parse a hex string to address
    /// @dev Expects "0x" prefix followed by 40 hex characters
    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42, "Invalid address length");
        require(b[0] == "0" && (b[1] == "x" || b[1] == "X"), "Missing 0x prefix");

        uint160 result = 0;
        for (uint256 i = 2; i < 42; i++) {
            uint8 digit = _hexCharToUint8(b[i]);
            result = result * 16 + digit;
        }
        return address(result);
    }

    /// @notice Convert a hex character to its numeric value
    function _hexCharToUint8(bytes1 c) internal pure returns (uint8) {
        if (c >= "0" && c <= "9") return uint8(c) - uint8(bytes1("0"));
        if (c >= "a" && c <= "f") return uint8(c) - uint8(bytes1("a")) + 10;
        if (c >= "A" && c <= "F") return uint8(c) - uint8(bytes1("A")) + 10;
        revert("Invalid hex character");
    }

    struct TempNode {
        string name;
        uint256 parent;
        string valueJson;
        bool hasValue;
    }

    /// @dev Address values stored as strings (either "0x..." literal or key reference)
    mapping(string => string) internal _addresses;
    mapping(string => string) internal _strings;
    mapping(string => uint256) internal _uints;
    mapping(string => int256) internal _ints;
    mapping(string => bool) internal _bools;

    /// @dev Address array values stored as string[] (each element is "0x..." or key reference)
    mapping(string => string[]) internal _addressArrays;
    mapping(string => string[]) internal _stringArrays;
    mapping(string => uint256[]) internal _uintArrays;
    mapping(string => int256[]) internal _intArrays;

    mapping(string => bool) internal _hasKey;
    string[] internal _dataKeys;

    // ============ Scalar Getters ============

    function get(string memory key) external view virtual override returns (address value) {
        // Shorthand: contracts.Oracle → contracts.Oracle.address
        string memory addressKey = string.concat(key, ".address");
        return _getAddress(addressKey);
    }

    function getAddress(string memory key) external view virtual override returns (address value) {
        return _getAddress(key);
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
        return _getAddressArray(key);
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

    /// @notice Set address for OBJECT type key (appends .address)
    /// @dev Stores the hex string representation
    function _set(string memory key, address value) internal {
        string memory addressKey = string.concat(key, ".address");
        _prepareKey(addressKey, DataType.ADDRESS);
        _addresses[addressKey] = LibString.toHexString(uint160(value), 20);
        _afterValueChanged(key);
    }

    /// @notice Get address for any key type (OBJECT, ADDRESS, or STRING reference)
    /// @dev OBJECT keys look up .address child, STRING keys look up referenced key
    function _get(string memory key) internal view returns (address) {
        if (keyType(key) == DataType.OBJECT) {
            return _getAddress(string.concat(key, ".address"));
        }
        return _getAddress(key);
    }

    function _has(string memory key) internal view returns (bool) {
        console2.log("checking for key '%s'...", key);
        if (_hasKey[key]) {
            console2.log("found '%s'.", key);
            return true;
        }
        if (keyType(key) == DataType.OBJECT) {
            console2.log("found OBJECT '%s'.", string.concat(key, ".address"));
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

    /// @notice Set address value (stores as string)
    /// @param key The key
    /// @param value The address to store (converted to hex string)
    function _setAddress(string memory key, address value) internal {
        _prepareKey(key, DataType.ADDRESS);
        _addresses[key] = LibString.toHexStringChecksummed(value);
        _afterValueChanged(key);
    }

    /// @notice Set address value from string (either "0x..." literal or key reference)
    /// @param key The key
    /// @param value The string value (stored as-is for later resolution)
    function _setAddressFromString(string memory key, string memory value) internal {
        _prepareKey(key, DataType.ADDRESS);
        _addresses[key] = value;
        _afterValueChanged(key);
    }

    /// @notice Get address value, resolving references if needed
    /// @dev If stored value starts with "0x", parses as address; otherwise looks up as key
    function _getAddress(string memory key) internal view returns (address) {
        _requireReadable(key, DataType.ADDRESS);
        string memory value = _addresses[key];
        return _resolveAddressValue(value);
    }

    /// @notice Get raw address string without resolution (for JSON output fallback)
    function _getAddressRaw(string memory key) internal view returns (string memory) {
        _requireReadable(key, DataType.ADDRESS);
        return _addresses[key];
    }

    /// @notice Resolve an address value string to an actual address
    /// @dev If starts with "0x", parse as literal; otherwise look up as key reference
    function _resolveAddressValue(string memory value) internal view returns (address) {
        if (value.startsWith("0x")) {
            return _parseAddress(value);
        }
        // It's a key reference - look it up (one level only, no recursion)
        return _getAddress(value);
    }

    /// @notice Try to resolve an address value, returning success status
    /// @dev Used for lenient JSON output - returns false if lookup fails
    function _tryResolveAddressValue(string memory value) internal view returns (bool success, address result) {
        if (value.startsWith("0x")) {
            return (true, _parseAddress(value));
        }
        // It's a key reference - try to look it up
        if (!_hasKey[value]) {
            return (false, address(0));
        }
        // Recursively try to resolve (but the referenced key must exist)
        string memory refValue = _addresses[value];
        return _tryResolveAddressValue(refValue);
    }

    /// @notice Set address array (from actual addresses)
    function _setAddressArray(string memory key, address[] memory values) internal {
        _prepareKey(key, DataType.ADDRESS_ARRAY);
        delete _addressArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _addressArrays[key].push(LibString.toHexString(uint160(values[i]), 20));
        }
        _afterValueChanged(key);
    }

    /// @notice Set address array from strings (either "0x..." literals or key references)
    function _setAddressArrayFromStrings(string memory key, string[] memory values) internal {
        _prepareKey(key, DataType.ADDRESS_ARRAY);
        delete _addressArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _addressArrays[key].push(values[i]);
        }
        _afterValueChanged(key);
    }

    /// @notice Get address array, resolving all references
    function _getAddressArray(string memory key) internal view returns (address[] memory result) {
        _requireReadable(key, DataType.ADDRESS_ARRAY);
        string[] memory raw = _addressArrays[key];
        result = new address[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            result[i] = _resolveAddressValue(raw[i]);
        }
    }

    /// @notice Get raw address array strings without resolution (for JSON output fallback)
    function _getAddressArrayRaw(string memory key) internal view returns (string[] memory) {
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
