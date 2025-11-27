// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DataType
 * @notice Enum for deployment data types
 * @dev Maps to JSON types with uint/int distinction for validation
 *      CONTRACT: Top-level deployed contracts (no dots in key)
 *      ADDRESS: Nested addresses (keys contain dots, e.g., "pegged.implementation")
 *      STRING: String values (keys contain dots, e.g., "token.symbol")
 *      UINT: Unsigned integer values (keys contain dots, e.g., "token.decimals")
 *      INT: Signed integer values (keys contain dots, e.g., "config.temperature")
 *      BOOL: Boolean values (keys contain dots, e.g., "config.enabled")
 *      ADDRESS_ARRAY: Array of addresses (keys contain dots, e.g., "config.validators")
 *      STRING_ARRAY: Array of strings (keys contain dots, e.g., "config.tags")
 *      UINT_ARRAY: Array of unsigned integers (keys contain dots, e.g., "config.limits")
 *      INT_ARRAY: Array of signed integers (keys contain dots, e.g., "config.deltas")
 */
enum DataType {
    CONTRACT,
    ADDRESS,
    STRING,
    UINT,
    INT,
    BOOL,
    ADDRESS_ARRAY,
    STRING_ARRAY,
    UINT_ARRAY,
    INT_ARRAY
}
