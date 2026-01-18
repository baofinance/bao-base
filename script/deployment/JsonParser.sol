// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {DateTimeLib} from "@solady/utils/DateTimeLib.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice JSON parsing for deployment state.
library JsonParser {
    using stdJson for string;

    uint256 internal constant SCHEMA_VERSION = 1;

    error SchemaMismatch(uint256 expected, uint256 found);
    error InvalidTimestamp(string input);
    error MissingRequiredField(string fieldName);

    function parseStateJson(string memory json) internal view returns (DeploymentTypes.State memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        DeploymentTypes.State memory state;

        if (bytes(json).length == 0) {
            return state;
        }

        if (json.keyExists(".schemaVersion")) {
            uint256 schema = json.readUint(".schemaVersion");
            if (schema != SCHEMA_VERSION) {
                revert SchemaMismatch(SCHEMA_VERSION, schema);
            }
        } else {
            revert SchemaMismatch(SCHEMA_VERSION, 0);
        }

        state.network = json.readString(".network");
        if (bytes(state.network).length == 0) {
            revert MissingRequiredField("network");
        }
        state.saltPrefix = json.readString(".saltPrefix");
        if (bytes(state.saltPrefix).length == 0) {
            revert MissingRequiredField("saltPrefix");
        }
        state.implementations = parseImplementations(json);
        state.proxies = parseProxies(json);
        state.baoFactory = vm.parseAddress(json.readString(".baoFactory"));
        return state;
    }

    function parseImplementations(
        string memory json
    ) internal view returns (DeploymentTypes.ImplementationRecord[] memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        if (!json.keyExists(".implementations")) {
            return new DeploymentTypes.ImplementationRecord[](0);
        }
        string[] memory keys = vm.parseJsonKeys(json, ".implementations");
        DeploymentTypes.ImplementationRecord[] memory records = new DeploymentTypes.ImplementationRecord[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = keys[i];
            string memory path = string.concat(".implementations['", key, "']");
            DeploymentTypes.ImplementationRecord memory rec;
            rec.implementation = vm.parseAddress(key);
            rec.proxy = json.readString(string.concat(path, ".proxy"));
            rec.contractSource = json.readString(string.concat(path, ".contractSource"));
            rec.contractType = json.readString(string.concat(path, ".contractType"));
            rec.deploymentTime = _parseTimestamp(json.readString(string.concat(path, ".deploymentTime")));
            records[i] = rec;
        }
        return records;
    }

    function parseProxies(string memory json) internal view returns (DeploymentTypes.ProxyRecord[] memory) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        if (!json.keyExists(".proxies")) {
            return new DeploymentTypes.ProxyRecord[](0);
        }
        string[] memory keys = vm.parseJsonKeys(json, ".proxies");
        DeploymentTypes.ProxyRecord[] memory records = new DeploymentTypes.ProxyRecord[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = keys[i];
            string memory path = string.concat(".proxies['", key, "']");
            DeploymentTypes.ProxyRecord memory rec;
            rec.id = key;
            rec.proxy = vm.parseAddress(json.readString(string.concat(path, ".address")));
            rec.implementation = vm.parseAddress(json.readString(string.concat(path, ".implementation")));
            rec.salt = json.readString(string.concat(path, ".salt"));
            rec.deploymentTime = _parseTimestamp(json.readString(string.concat(path, ".deploymentTime")));
            records[i] = rec;
        }
        return records;
    }

    function _parseTimestamp(string memory value) private pure returns (uint64) {
        bytes memory data = bytes(value);
        if (data.length == 0) {
            return 0;
        }
        if (
            data.length != 20 ||
            data[4] != "-" ||
            data[7] != "-" ||
            data[10] != "T" ||
            data[13] != ":" ||
            data[16] != ":" ||
            data[19] != "Z"
        ) {
            revert InvalidTimestamp(value);
        }
        uint256 year = _parseDigits(data, 0, 4);
        uint256 month = _parseDigits(data, 5, 2);
        uint256 day = _parseDigits(data, 8, 2);
        uint256 hour = _parseDigits(data, 11, 2);
        uint256 minute = _parseDigits(data, 14, 2);
        uint256 second = _parseDigits(data, 17, 2);
        return uint64(DateTimeLib.dateTimeToTimestamp(year, month, day, hour, minute, second));
    }

    function _parseDigits(bytes memory data, uint256 start, uint256 length) private pure returns (uint256 result) {
        for (uint256 i = 0; i < length; ++i) {
            uint8 c = uint8(data[start + i]);
            if (c < 48 || c > 57) revert InvalidTimestamp(string(data));
            result = result * 10 + (c - 48);
        }
    }
}
