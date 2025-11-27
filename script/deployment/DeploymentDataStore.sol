// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDeploymentDataWritable} from "./interfaces/IDeploymentDataWritable.sol";
import {DataType} from "./DataType.sol";
import {DeploymentKeys} from "./DeploymentKeys.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title DeploymentDataStore
 * @notice Canonical in-memory data store shared by all deployment data layers
 * @dev Provides type-safe value storage plus deterministic JSON rendering
 */
abstract contract DeploymentDataStore is IDeploymentDataWritable {
    using stdJson for string;

    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ValueNotSet(string key);
    error ReadTypeMismatch(string key, DataType expectedType, DataType actualType);

    struct TempNode {
        string name;
        uint256 parent;
        string valueJson;
        bool hasValue;
    }

    DeploymentKeys internal immutable _keyRegistry;
    bool private _suppressPersistence;

    mapping(string => address) private _addresses;
    mapping(string => string) private _strings;
    mapping(string => uint256) private _uints;
    mapping(string => int256) private _ints;
    mapping(string => bool) private _bools;

    mapping(string => address[]) private _addressArrays;
    mapping(string => string[]) private _stringArrays;
    mapping(string => uint256[]) private _uintArrays;
    mapping(string => int256[]) private _intArrays;

    mapping(string => DataType) private _types;
    mapping(string => bool) private _hasKey;
    string[] private _allKeys;

    constructor(DeploymentKeys keyRegistry) {
        _keyRegistry = keyRegistry;
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

    function _afterValueChanged(string memory /*key*/) internal virtual {}

    // ============ Shared Logic ============

    function _writeAddress(string memory key, address value, DataType expected) private {
        _prepareKey(key, expected);
        _addresses[key] = value;
        _finalizeWrite(key);
    }

    function _writeString(string memory key, string memory value, DataType expected) private {
        _prepareKey(key, expected);
        _strings[key] = value;
        _finalizeWrite(key);
    }

    function _writeUint(string memory key, uint256 value, DataType expected) private {
        _prepareKey(key, expected);
        _uints[key] = value;
        _finalizeWrite(key);
    }

    function _writeInt(string memory key, int256 value, DataType expected) private {
        _prepareKey(key, expected);
        _ints[key] = value;
        _finalizeWrite(key);
    }

    function _writeBool(string memory key, bool value, DataType expected) private {
        _prepareKey(key, expected);
        _bools[key] = value;
        _finalizeWrite(key);
    }

    function _writeAddressArray(string memory key, address[] memory values, DataType expected) private {
        _prepareKey(key, expected);
        delete _addressArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _addressArrays[key].push(values[i]);
        }
        _finalizeWrite(key);
    }

    function _writeStringArray(string memory key, string[] memory values, DataType expected) private {
        _prepareKey(key, expected);
        delete _stringArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _stringArrays[key].push(values[i]);
        }
        _finalizeWrite(key);
    }

    function _writeUintArray(string memory key, uint256[] memory values, DataType expected) private {
        _prepareKey(key, expected);
        delete _uintArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _uintArrays[key].push(values[i]);
        }
        _finalizeWrite(key);
    }

    function _writeIntArray(string memory key, int256[] memory values, DataType expected) private {
        _prepareKey(key, expected);
        delete _intArrays[key];
        for (uint256 i = 0; i < values.length; i++) {
            _intArrays[key].push(values[i]);
        }
        _finalizeWrite(key);
    }

    function _prepareKey(string memory key, DataType expected) private {
        _keyRegistry.validateKey(key, expected);
        if (!_hasKey[key]) {
            _hasKey[key] = true;
            _allKeys.push(key);
        }
        _types[key] = expected;
    }

    function _finalizeWrite(string memory key) private {
        if (_suppressPersistence) {
            return;
        }
        _afterValueChanged(key);
    }

    // ============ Bootstrap ============

    function _loadFromJson(string memory existingJson) internal {
        if (bytes(existingJson).length == 0) {
            return;
        }

        string[] memory registered = _keyRegistry.getAllKeys();
        _suppressPersistence = true;
        for (uint256 i = 0; i < registered.length; i++) {
            string memory key = registered[i];
            string memory pointer = string.concat("$.", key);
            if (!existingJson.keyExists(pointer)) {
                continue;
            }
            DataType expected = _keyRegistry.getKeyType(key);
            if (_shouldSkipComposite(existingJson, pointer, expected)) {
                continue;
            }
            if (expected == DataType.CONTRACT || expected == DataType.ADDRESS) {
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
        _suppressPersistence = false;
    }

    // ============ JSON Rendering ============

    function _renderJson() internal returns (string memory) {
        uint256 keyCount = _allKeys.length;
        if (keyCount == 0) {
            return "{}";
        }

        uint256 maxSegments = 1;
        for (uint256 i = 0; i < keyCount; i++) {
            maxSegments += _segmentCount(_allKeys[i]);
        }

        TempNode[] memory nodes = new TempNode[](maxSegments);
        nodes[0].parent = type(uint256).max;
        uint256 nodeCount = 1;

        for (uint256 i = 0; i < keyCount; i++) {
            string memory key = _allKeys[i];
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
            nodes[current].hasValue = true;
            nodes[current].valueJson = _encodeValue(key, _types[key]);
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
        if (valueType == DataType.CONTRACT || valueType == DataType.ADDRESS) {
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
        string memory tmp = _vm.serializeString("__bao_string", "value", value);
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

    function _currentJson() internal returns (string memory) {
        return _renderJson();
    }

    function _requireReadable(string memory key, DataType expected) private view {
        if (!_hasKey[key]) {
            revert ValueNotSet(key);
        }
        if (_types[key] != expected) {
            revert ReadTypeMismatch(key, expected, _types[key]);
        }
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
        try _vm.parseJsonKeys(json, pointer) returns (string[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    function toJson() external returns (string memory) {
        return _currentJson();
    }
}
