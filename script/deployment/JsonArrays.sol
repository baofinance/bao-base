// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title JsonArrays
 * @notice Helper library for serializing arrays to JSON
 * @dev Extends stdJson with array serialization support for deployment data
 */
library JsonArrays {
    using stdJson for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ============ Address Arrays ============

    /**
     * @notice Serialize address array to JSON
     * @param objectKey The JSON object key to serialize into
     * @param valueKey The key for this array value
     * @param values The address array to serialize
     * @return json The serialized JSON string
     */
    function serializeAddressArray(
        string memory objectKey,
        string memory valueKey,
        address[] memory values
    ) internal returns (string memory json) {
        return vm.serializeAddress(objectKey, valueKey, values);
    }

    /**
     * @notice Read address array from JSON
     * @param json The JSON string to parse
     * @param key The JSON pointer path to the array
     * @return values The parsed address array
     */
    function readAddressArray(string memory json, string memory key) internal pure returns (address[] memory values) {
        return json.readAddressArray(key);
    }

    // ============ String Arrays ============

    /**
     * @notice Serialize string array to JSON
     * @param objectKey The JSON object key to serialize into
     * @param valueKey The key for this array value
     * @param values The string array to serialize
     * @return json The serialized JSON string
     */
    function serializeStringArray(
        string memory objectKey,
        string memory valueKey,
        string[] memory values
    ) internal returns (string memory json) {
        return vm.serializeString(objectKey, valueKey, values);
    }

    /**
     * @notice Read string array from JSON
     * @param json The JSON string to parse
     * @param key The JSON pointer path to the array
     * @return values The parsed string array
     */
    function readStringArray(string memory json, string memory key) internal pure returns (string[] memory values) {
        return json.readStringArray(key);
    }

    // ============ Uint256 Arrays ============

    /**
     * @notice Serialize uint256 array to JSON
     * @param objectKey The JSON object key to serialize into
     * @param valueKey The key for this array value
     * @param values The uint256 array to serialize
     * @return json The serialized JSON string
     */
    function serializeUintArray(
        string memory objectKey,
        string memory valueKey,
        uint256[] memory values
    ) internal returns (string memory json) {
        return vm.serializeUint(objectKey, valueKey, values);
    }

    /**
     * @notice Read uint256 array from JSON
     * @param json The JSON string to parse
     * @param key The JSON pointer path to the array
     * @return values The parsed uint256 array
     */
    function readUintArray(string memory json, string memory key) internal pure returns (uint256[] memory values) {
        return json.readUintArray(key);
    }

    // ============ Int256 Arrays ============

    /**
     * @notice Serialize int256 array to JSON
     * @param objectKey The JSON object key to serialize into
     * @param valueKey The key for this array value
     * @param values The int256 array to serialize
     * @return json The serialized JSON string
     */
    function serializeIntArray(
        string memory objectKey,
        string memory valueKey,
        int256[] memory values
    ) internal returns (string memory json) {
        return vm.serializeInt(objectKey, valueKey, values);
    }

    /**
     * @notice Read int256 array from JSON
     * @param json The JSON string to parse
     * @param key The JSON pointer path to the array
     * @return values The parsed int256 array
     */
    function readIntArray(string memory json, string memory key) internal pure returns (int256[] memory values) {
        return json.readIntArray(key);
    }
}
