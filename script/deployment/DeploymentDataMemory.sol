// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibString} from "@solady/utils/LibString.sol";
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
    error RoleValueMismatch(string roleKey, uint256 existingValue, uint256 newValue);
    error DuplicateGrantee(string roleKey, string granteeKey);

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

    // ============ Role Storage ============
    // Role values and grantees are stored via schema keys:
    //   - "{contractKey}.roles.{roleName}.value" (UINT)
    //   - "{contractKey}.roles.{roleName}.grantees" (STRING_ARRAY)
    // Only _contractRoleNames is kept for enumeration during serialization.

    /// @dev Role names registered for each contract (for enumeration during serialization)
    mapping(string => string[]) internal _contractRoleNames;

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
        string memory lookup = key;
        if (keyType(key) == DataType.OBJECT) {
            lookup = string.concat(key, ".address");
        }
        _requireReadable(lookup, DataType.ADDRESS);
        return _addresses[lookup];
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
        _requireReadable(key, DataType.ADDRESS);
        return _addresses[key];
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

    // ============ Role Functions ============

    /// @notice Build the role key from contract key and role name
    /// @dev Returns "{contractKey}.roles.{roleName}" (e.g., "contracts.pegged.roles.MINTER_ROLE")
    function _roleKey(string memory contractKey, string memory roleName) internal pure returns (string memory) {
        return string.concat(contractKey, ".roles.", roleName);
    }

    /// @notice Register a role's value for a contract
    /// @dev Reverts if a different value is already registered for this role.
    ///      Dynamically registers schema keys for the role value and grantees.
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    /// @param value The role's uint256 bitmask value
    function _registerRole(string memory contractKey, string memory roleName, uint256 value) internal {
        string memory roleKey = _roleKey(contractKey, roleName);
        string memory valueKey = string.concat(roleKey, ".value");
        string memory granteesKey = string.concat(roleKey, ".grantees");

        // Check if already registered with different value
        if (_hasKey[valueKey]) {
            uint256 existingValue = _uints[valueKey];
            if (existingValue != value) {
                revert RoleValueMismatch(roleKey, existingValue, value);
            }
            // Same value, no-op
            return;
        }

        // Dynamically register schema keys for this role
        addUintKey(valueKey);
        addStringArrayKey(granteesKey);

        // Set the value
        _setUint(valueKey, value);

        // Initialize empty grantees array
        string[] memory emptyArray = new string[](0);
        _setStringArray(granteesKey, emptyArray);

        // Track role name for this contract (for enumeration during serialization)
        _contractRoleNames[contractKey].push(roleName);
    }

    /// @notice Register a grantee for a role
    /// @dev Reverts if the grantee is already registered for this role
    /// @param granteeKey The grantee's contract key (e.g., "contracts.minter")
    /// @param contractKey The contract key where the role is defined (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    function _registerGrantee(string memory granteeKey, string memory contractKey, string memory roleName) internal {
        string memory roleKey = _roleKey(contractKey, roleName);
        string memory granteesKey = string.concat(roleKey, ".grantees");

        // Get current grantees
        string[] memory currentGrantees = _stringArrays[granteesKey];

        // Check for duplicate grantee
        for (uint256 i = 0; i < currentGrantees.length; i++) {
            if (LibString.eq(currentGrantees[i], granteeKey)) {
                revert DuplicateGrantee(roleKey, granteeKey);
            }
        }

        // Append to grantees array
        _stringArrays[granteesKey].push(granteeKey);
        _afterValueChanged(granteesKey);
    }

    /// @notice Get the role value for a contract's role
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    /// @return value The role's uint256 bitmask value
    function _getRoleValue(string memory contractKey, string memory roleName) internal view returns (uint256 value) {
        string memory valueKey = string.concat(_roleKey(contractKey, roleName), ".value");
        return _getUint(valueKey);
    }

    /// @notice Check if a role value is set
    function _hasRoleValue(string memory contractKey, string memory roleName) internal view returns (bool) {
        string memory valueKey = string.concat(_roleKey(contractKey, roleName), ".value");
        return _hasKey[valueKey];
    }

    /// @notice Get the grantees for a contract's role
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    /// @return grantees Array of grantee contract keys
    function _getRoleGrantees(
        string memory contractKey,
        string memory roleName
    ) internal view returns (string[] memory grantees) {
        string memory granteesKey = string.concat(_roleKey(contractKey, roleName), ".grantees");
        return _getStringArray(granteesKey);
    }

    /// @notice Get all role names registered for a contract
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @return roleNames Array of role names
    function _getContractRoleNames(string memory contractKey) internal view returns (string[] memory roleNames) {
        return _contractRoleNames[contractKey];
    }

    /// @notice Compute the expected role bitmap for a grantee on a contract
    /// @dev Iterates all roles on contractKey and ORs values where granteeKey is a grantee
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param granteeKey The grantee's contract key (e.g., "contracts.minter")
    /// @return bitmap The combined role bitmap
    function _computeExpectedRoles(
        string memory contractKey,
        string memory granteeKey
    ) internal view returns (uint256 bitmap) {
        string[] memory roleNames = _contractRoleNames[contractKey];
        for (uint256 i = 0; i < roleNames.length; i++) {
            string memory roleKey = _roleKey(contractKey, roleNames[i]);
            string memory granteesKey = string.concat(roleKey, ".grantees");
            string[] memory grantees = _stringArrays[granteesKey];
            for (uint256 j = 0; j < grantees.length; j++) {
                if (LibString.eq(grantees[j], granteeKey)) {
                    string memory valueKey = string.concat(roleKey, ".value");
                    bitmap |= _uints[valueKey];
                    break;
                }
            }
        }
    }
}
