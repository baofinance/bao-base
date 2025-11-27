// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDeploymentData} from "./IDeploymentData.sol";
import {DataType} from "../DataType.sol";

/**
 * @title IDeploymentDataWritable
 * @notice Read-write interface for deployment configuration and logging
 * @dev Extends IDeploymentData with write operations and previous deployment history
 *      Number type aligns with JSON (no separate uint/int)
 */
interface IDeploymentDataWritable is IDeploymentData {
    // ============ Scalar Setters ============

    /**
     * @notice Set deployed contract address (CONTRACT type)
     * @dev For top-level deployed contracts (no dots in key)
     * @param key The configuration key (e.g., "owner", "token")
     * @param value The contract address to set
     */
    function set(string memory key, address value) external;

    /**
     * @notice Set nested address value (ADDRESS type)
     * @dev For addresses within config hierarchy (keys contain dots)
     * @param key The configuration key (e.g., "pegged.implementation")
     * @param value The address value to set
     */
    function setAddress(string memory key, address value) external;

    /**
     * @notice Set string value for key
     * @param key The configuration key (e.g., "version", "pegged.symbol")
     * @param value The string value to set
     */
    function setString(string memory key, string memory value) external;

    /**
     * @notice Set number value for key from uint256
     * @dev Stored as JSON number, type tracked as UINT
     * @param key The configuration key (e.g., "pegged.decimals")
     * @param value The number value to set
     */
    function setUint(string memory key, uint256 value) external;

    /**
     * @notice Set number value for key from int256
     * @dev Stored as JSON number, type tracked as INT
     * @param key The configuration key
     * @param value The number value to set
     */
    function setInt(string memory key, int256 value) external;

    /**
     * @notice Set bool value for key
     * @param key The configuration key
     * @param value The bool value to set
     */
    function setBool(string memory key, bool value) external;

    // ============ Array Setters ============

    /**
     * @notice Set address array for key (replaces entire array)
     * @param key The configuration key
     * @param values The address array to set
     */
    function setAddressArray(string memory key, address[] memory values) external;

    /**
     * @notice Set string array for key (replaces entire array)
     * @param key The configuration key
     * @param values The string array to set
     */
    function setStringArray(string memory key, string[] memory values) external;

    /**
     * @notice Set number array for key from uint256[] (replaces entire array)
     * @dev Stored as JSON number array, type tracked as UINT_ARRAY
     * @param key The configuration key
     * @param values The number array to set
     */
    function setUintArray(string memory key, uint256[] memory values) external;

    /**
     * @notice Set number array for key from int256[] (replaces entire array)
     * @dev Stored as JSON number array, type tracked as INT_ARRAY
     * @param key The configuration key
     * @param values The number array to set
     */
    function setIntArray(string memory key, int256[] memory values) external;
}
