// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IDeploymentData
 * @notice Read-only interface for deployment configuration and state
 * @dev Provides type-safe access to deployment parameters and deployed contract addresses
 *      Number type aligns with JSON (no separate uint/int)
 */
interface IDeploymentData {
    // ============ Scalar Getters ============

    /**
     * @notice Get deployed contract address (CONTRACT type)
     * @dev For top-level deployed contracts (no dots in key)
     * @param key The configuration key (e.g., "owner", "token")
     * @return value The contract address
     */
    function get(string memory key) external view returns (address value);

    /**
     * @notice Get nested address value (ADDRESS type)
     * @dev For addresses within config hierarchy (keys contain dots)
     * @param key The configuration key (e.g., "pegged.implementation")
     * @return value The address value
     */
    function getAddress(string memory key) external view returns (address value);

    /**
     * @notice Get string value for key
     * @param key The configuration key (e.g., "version", "pegged.symbol")
     * @return value The string value
     */
    function getString(string memory key) external view returns (string memory value);

    /**
     * @notice Get number value for key as uint256
     * @dev JSON number must be non-negative and fit in uint256
     * @param key The configuration key (e.g., "pegged.decimals")
     * @return value The number value as uint256
     */
    function getUint(string memory key) external view returns (uint256 value);

    /**
     * @notice Get number value for key as int256
     * @dev JSON number must fit in int256 range
     * @param key The configuration key
     * @return value The number value as int256
     */
    function getInt(string memory key) external view returns (int256 value);

    /**
     * @notice Get bool value for key
     * @param key The configuration key
     * @return value The bool value
     */
    function getBool(string memory key) external view returns (bool value);

    // ============ Array Getters ============

    /**
     * @notice Get address array for key
     * @param key The configuration key
     * @return values The address array (entire array, no element access)
     */
    function getAddressArray(string memory key) external view returns (address[] memory values);

    /**
     * @notice Get string array for key
     * @param key The configuration key
     * @return values The string array (entire array, no element access)
     */
    function getStringArray(string memory key) external view returns (string[] memory values);

    /**
     * @notice Get number array for key as uint256[]
     * @dev JSON numbers must be non-negative and fit in uint256
     * @param key The configuration key
     * @return values The number array as uint256[]
     */
    function getUintArray(string memory key) external view returns (uint256[] memory values);

    /**
     * @notice Get number array for key as int256[]
     * @dev JSON numbers must fit in int256 range
     * @param key The configuration key
     * @return values The number array as int256[]
     */
    function getIntArray(string memory key) external view returns (int256[] memory values);

    // ============ Introspection ============

    /**
     * @notice Check if key exists
     * @param key The configuration key to check
     * @return exists True if key has been set
     */
    function has(string memory key) external view returns (bool exists);

    /**
     * @notice Get all keys that have been set
     * @return allKeys Array of all configuration keys
     */
    function keys() external view returns (string[] memory allKeys);
}
