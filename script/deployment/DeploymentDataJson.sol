// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibString} from "@solady/utils/LibString.sol";

import {DeploymentKeys, DataType} from "./DeploymentKeys.sol";
import {DeploymentDataMemory} from "./DeploymentDataMemory.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title DeploymentDataJson
 * @notice JSON serialization/deserialization for deployment data
 * @dev Extends DeploymentDataMemory with JSON capabilities
 */
abstract contract DeploymentDataJson is DeploymentDataMemory {
    using stdJson for string;
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Get base directory for deployment files
    /// @dev Override in test classes to use results/ instead of ./
    /// @return Base directory path
    function _getPrefix() internal view virtual returns (string memory) {
        return ".";
    }

    function fromJson(string memory existingJson) public {
        if (bytes(existingJson).length == 0) {
            return;
        }

        string[] memory registered = this.schemaKeys();
        for (uint256 i = 0; i < registered.length; i++) {
            string memory key = registered[i];
            string memory pointer = string.concat("$.", key);
            if (!existingJson.keyExists(pointer)) {
                continue;
            }
            DataType expected = this.keyType(key);
            if (_shouldSkipComposite(existingJson, pointer, expected)) {
                continue;
            }
            // Skip OBJECT type - it's a parent marker with no value
            if (expected == DataType.OBJECT) {
                continue;
            }
            if (expected == DataType.ADDRESS) {
                _writeAddress(key, existingJson.readAddress(pointer), expected);
            } else if (expected == DataType.STRING) {
                _writeString(key, existingJson.readString(pointer), expected);
            } else if (expected == DataType.UINT) {
                _writeUint(key, existingJson.readUint(pointer), expected);
            } else if (expected == DataType.INT) {
                _writeInt(key, existingJson.readInt(pointer), expected);
            } else if (expected == DataType.BOOL) {
                _writeBool(key, existingJson.readBool(pointer), expected);
            } else if (expected == DataType.ADDRESS_ARRAY) {
                _writeAddressArray(key, existingJson.readAddressArray(pointer), expected);
            } else if (expected == DataType.STRING_ARRAY) {
                _writeStringArray(key, existingJson.readStringArray(pointer), expected);
            } else if (expected == DataType.UINT_ARRAY) {
                _writeUintArray(key, existingJson.readUintArray(pointer), expected);
            } else if (expected == DataType.INT_ARRAY) {
                _writeIntArray(key, existingJson.readIntArray(pointer), expected);
            }
        }
    }

    // ============ JSON Rendering ============

    function toJson() public returns (string memory) {
        uint256 keyCount = _dataKeys.length;
        if (keyCount == 0) {
            return "{}";
        }

        uint256 maxSegments = 1;
        for (uint256 i = 0; i < keyCount; i++) {
            maxSegments += _segmentCount(_dataKeys[i]);
        }

        TempNode[] memory nodes = new TempNode[](maxSegments);
        nodes[0].parent = type(uint256).max;
        uint256 nodeCount = 1;

        for (uint256 i = 0; i < keyCount; i++) {
            string memory key = _dataKeys[i];
            if (!_hasKey[key]) {
                continue;
            }
            string[] memory segments = _splitKey(key);
            uint256 current = 0;
            for (uint256 j = 0; j < segments.length; j++) {
                uint256 child = _findChild(nodes, nodeCount, current, segments[j]);
                if (child == type(uint256).max) {
                    child = nodeCount;
                    nodes[child].name = segments[j];
                    nodes[child].parent = current;
                    nodeCount++;
                }
                current = child;
            }
            // OBJECT type nodes are parent markers with no value
            if (_types[key] != DataType.OBJECT) {
                nodes[current].hasValue = true;
                nodes[current].valueJson = _encodeValue(key, _types[key]);
            }
        }

        return _renderNode(0, nodes, nodeCount);
    }

    function _renderNode(uint256 index, TempNode[] memory nodes, uint256 nodeCount) private returns (string memory) {
        bool hasChild = false;
        string memory json = "{";
        bool first = true;
        for (uint256 i = 1; i < nodeCount; i++) {
            if (nodes[i].parent == index) {
                hasChild = true;
                string memory childJson = _renderNode(i, nodes, nodeCount);
                json = string.concat(json, first ? "" : ",", '"', nodes[i].name, '"', ":", childJson);
                first = false;
            }
        }

        if (!hasChild) {
            if (index == 0) {
                return "{}";
            }
            return nodes[index].valueJson;
        }

        json = string.concat(json, "}");
        return json;
    }

    function _segmentCount(string memory key) private pure returns (uint256 count) {
        bytes memory data = bytes(key);
        count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == 0x2E) {
                count++;
            }
        }
    }

    function _splitKey(string memory key) private pure returns (string[] memory segments) {
        uint256 count = _segmentCount(key);
        segments = new string[](count);
        bytes memory data = bytes(key);
        uint256 segmentIndex = 0;
        uint256 start = 0;
        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == 0x2E) {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = data[j];
                }
                segments[segmentIndex++] = string(slice);
                start = i + 1;
            }
        }
    }

    function _findChild(
        TempNode[] memory nodes,
        uint256 nodeCount,
        uint256 parent,
        string memory name
    ) private pure returns (uint256) {
        for (uint256 i = 1; i < nodeCount; i++) {
            if (nodes[i].parent == parent && _equals(nodes[i].name, name)) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _equals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _encodeValue(string memory key, DataType valueType) private returns (string memory) {
        // Skip OBJECT type - it's a parent marker with no value
        if (valueType == DataType.OBJECT) {
            return "";
        }
        if (valueType == DataType.ADDRESS) {
            return _encodeAddressValue(_addresses[key]);
        }
        if (valueType == DataType.STRING) {
            return _encodeStringValue(_strings[key]);
        }
        if (valueType == DataType.UINT) {
            return LibString.toString(_uints[key]);
        }
        if (valueType == DataType.INT) {
            return LibString.toString(_ints[key]);
        }
        if (valueType == DataType.BOOL) {
            return _bools[key] ? "true" : "false";
        }
        if (valueType == DataType.ADDRESS_ARRAY) {
            return _encodeAddressArrayValue(_addressArrays[key]);
        }
        if (valueType == DataType.STRING_ARRAY) {
            return _encodeStringArrayValue(_stringArrays[key]);
        }
        if (valueType == DataType.UINT_ARRAY) {
            return _encodeUintArrayValue(_uintArrays[key]);
        }
        if (valueType == DataType.INT_ARRAY) {
            return _encodeIntArrayValue(_intArrays[key]);
        }
        revert("DeploymentDataStore: unsupported type");
    }

    function _encodeAddressValue(address value) private pure returns (string memory) {
        return string.concat('"', LibString.toHexString(uint160(value), 20), '"');
    }

    function _encodeStringValue(string memory value) private returns (string memory) {
        string memory tmp = VM.serializeString("__bao_string", "value", value);
        return _extractSerializedValue(tmp);
    }

    function _encodeAddressArrayValue(address[] storage values) private view returns (string memory) {
        if (values.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < values.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", _encodeAddressValue(values[i]));
        }
        return string.concat(json, "]");
    }

    function _encodeStringArrayValue(string[] storage values) private returns (string memory) {
        if (values.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < values.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", _encodeStringValue(values[i]));
        }
        return string.concat(json, "]");
    }

    function _encodeUintArrayValue(uint256[] storage values) private view returns (string memory) {
        if (values.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < values.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", LibString.toString(values[i]));
        }
        return string.concat(json, "]");
    }

    function _encodeIntArrayValue(int256[] storage values) private view returns (string memory) {
        if (values.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < values.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", LibString.toString(values[i]));
        }
        return string.concat(json, "]");
    }

    function _extractSerializedValue(string memory valueJson) private pure returns (string memory) {
        bytes memory json = bytes(valueJson);
        uint256 colonPos = 0;
        for (uint256 i = 0; i < json.length; i++) {
            if (json[i] == 0x3A) {
                colonPos = i;
                break;
            }
        }
        uint256 valueStart = colonPos + 1;
        while (valueStart < json.length && (json[valueStart] == 0x20 || json[valueStart] == 0x09)) {
            valueStart++;
        }
        uint256 valueEnd = json.length - 1;
        while (valueEnd > valueStart && (json[valueEnd] == 0x7D || json[valueEnd] == 0x20)) {
            valueEnd--;
        }
        valueEnd++;
        bytes memory valueBytes = new bytes(valueEnd - valueStart);
        for (uint256 i = valueStart; i < valueEnd; i++) {
            valueBytes[i - valueStart] = json[i];
        }
        return string(valueBytes);
    }

    function _shouldSkipComposite(
        string memory json,
        string memory pointer,
        DataType expected
    ) private pure returns (bool) {
        if (!_isJsonObject(json, pointer)) {
            return false;
        }

        bool isArrayType = expected == DataType.ADDRESS_ARRAY ||
            expected == DataType.STRING_ARRAY ||
            expected == DataType.UINT_ARRAY ||
            expected == DataType.INT_ARRAY;

        // Objects are only meaningful for namespace containers; skip unless an array was explicitly expected
        return !isArrayType;
    }

    function _isJsonObject(string memory json, string memory pointer) private pure returns (bool) {
        try VM.parseJsonKeys(json, pointer) returns (string[] memory) {
            return true;
        } catch {
            return false;
        }
    }
}
