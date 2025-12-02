// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O and serialization
 * @dev Extends base Deployment with:
 *      - JSON file path resolution (input/output)
 *      - Timestamp-based file naming
 *      - JSON serialization/deserialization (merged from DeploymentDataJson)
 *      - Production BaoDeployer operator verification
 *
 * This file is structured in two sections for easy verification:
 * 1. FROM DeploymentJson.sol - File I/O, path resolution, lifecycle
 * 2. FROM DeploymentDataJson.sol - JSON serialization/deserialization
 */
contract DeploymentJson is Deployment {
    using LibString for string;
    using stdJson for string;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ============================================================================
    // ============ FROM DeploymentJson.sol ============
    // ============================================================================

    string private _systemSaltString;
    string private _network;
    string private _filename;
    bool private _suppressIncrementalPersistence = false;

    constructor() {
        _filename = _formatTimestamp(block.timestamp);
    }

    // ============================================================================
    // Abstract Methods for JSON Configuration
    // ============================================================================

    function _afterValueChanged(string memory /* key */) internal virtual override {
        if (!_suppressIncrementalPersistence) {
            _save();
        }
    }

    function _save() internal virtual {
        VM.createDir(_getOutputConfigDir(), true); // recursive=true, creates parent dirs if needed
        VM.writeJson(toJson(), _getOutputConfigPath());
    }

    // ============================================================================
    // Path Calculation
    // ============================================================================

    /// @notice Get base directory for deployment files
    /// @dev Override in test classes to use results/ instead of ./
    /// @return Base directory path
    function _getPrefix() internal virtual returns (string memory) {
        return ".";
    }

    function _getRoot() private returns (string memory) {
        return string.concat(_getPrefix(), "/deployments");
    }

    function _getStartConfigDir() internal returns (string memory) {
        return string.concat(_getRoot(), "/", _systemSaltString);
    }

    function _getOutputConfigDir() internal returns (string memory) {
        if (bytes(_network).length > 0) return string.concat(_getRoot(), "/", _systemSaltString, "/", _network);
        else return string.concat(_getRoot(), "/", _systemSaltString);
    }

    function _getOutputConfigPath() internal returns (string memory) {
        return string.concat(_getOutputConfigDir(), "/", _getFilename(), ".json");
    }

    function _getFilename() internal view virtual returns (string memory filename) {
        filename = _filename;
    }
    // ============================================================================
    // Lifecycle Override with JSON Support
    // ============================================================================
    function _requireNetwork(string memory network_) internal virtual {
        require(bytes(network_).length > 0, "cannot have a null network string");
    }

    /// @notice Start deployment session with JSON file loading
    /// @dev Overrides Deployment.start() to load initial state from JSON
    /// @param network_ Network name
    /// @param systemSaltString_ System salt string
    /// @param deployer Address that will sign transactions (EOA for scripts, harness for tests)
    /// @param startPoint Start point for input resolution ("first", "latest", or timestamp)
    function start(
        string memory network_,
        string memory systemSaltString_,
        address deployer,
        string memory startPoint
    ) public virtual override {
        _requireNetwork(network_);
        require(bytes(systemSaltString_).length > 0, "cannot have a null system salt string");

        _network = network_;
        _systemSaltString = systemSaltString_;

        // Load initial data from the specified file
        string memory path;
        if (bytes(startPoint).length == 0 || startPoint.eq("first")) {
            path = string.concat(_getStartConfigDir(), "/config.json");
        } else if (startPoint.eq("latest")) {
            path = _findLatestFile();
        } else {
            path = string.concat(_getOutputConfigDir(), "/", startPoint, ".json");
        }
        fromJson(VM.readFile(path));

        // Now call parent to set up session metadata
        super.start(network_, systemSaltString_, deployer, startPoint);
    }

    /// @notice Find the latest JSON file in the output directory
    /// @dev Uses lexicographic sorting of ISO 8601 timestamps
    /// @return Full path to the latest JSON file
    function _findLatestFile() private returns (string memory) {
        string memory dir = _getOutputConfigDir();
        Vm.DirEntry[] memory entries = VM.readDir(dir, 1); // maxDepth=1, no recursion

        string memory latestFile;
        string memory latestName;

        for (uint256 i = 0; i < entries.length; i++) {
            // Skip directories, symlinks, and errors
            if (entries[i].isDir || entries[i].isSymlink || bytes(entries[i].errorMessage).length > 0) {
                continue;
            }

            // Extract filename from path
            string memory fullPath = entries[i].path;
            string memory filename = _extractFilename(fullPath);

            // Skip config.json
            if (filename.eq("config.json")) {
                continue;
            }

            // Only consider .json files
            if (!filename.endsWith(".json")) {
                continue;
            }

            // Compare filenames (ISO 8601 timestamps sort lexicographically)
            if (bytes(latestName).length == 0 || filename.cmp(latestName) > 0) {
                latestName = filename;
                latestFile = fullPath;
            }
        }

        require(bytes(latestFile).length > 0, "No deployment files found in directory");
        return latestFile;
    }

    /// @notice Extract filename from a full path
    function _extractFilename(string memory path) private pure returns (string memory) {
        uint256 lastSlashIndex = path.lastIndexOf("/");
        // If not found, return whole path; otherwise slice from after the slash
        return lastSlashIndex == LibString.NOT_FOUND ? path : path.slice(lastSlashIndex + 1);
    }

    // ============================================================================
    // ============ FROM DeploymentDataJson.sol ============
    // ============================================================================

    // Note: _getPrefix() is already defined above in DeploymentJson section

    function _fromJsonNoSave(string memory existingJson) internal {
        if (bytes(existingJson).length == 0) {
            return;
        }

        _suppressIncrementalPersistence = true; // we don't want the loading to write out each change, on loading

        string[] memory registered = schemaKeys();
        for (uint256 i = 0; i < registered.length; i++) {
            string memory key = registered[i];
            string memory pointer = string.concat("$.", key);
            if (!existingJson.keyExists(pointer)) {
                continue;
            }
            DataType expected = keyType(key);
            if (_shouldSkipComposite(existingJson, pointer, expected)) {
                continue;
            }
            // Skip OBJECT type - it's a parent marker with no value
            if (expected == DataType.OBJECT) {
                continue;
            }
            if (expected == DataType.ADDRESS) {
                _setAddress(key, existingJson.readAddress(pointer));
            } else if (expected == DataType.STRING) {
                _setString(key, existingJson.readString(pointer));
            } else if (expected == DataType.UINT) {
                _setUint(key, existingJson.readUint(pointer));
            } else if (expected == DataType.INT) {
                _setInt(key, existingJson.readInt(pointer));
            } else if (expected == DataType.BOOL) {
                _setBool(key, existingJson.readBool(pointer));
            } else if (expected == DataType.ADDRESS_ARRAY) {
                _setAddressArray(key, existingJson.readAddressArray(pointer));
            } else if (expected == DataType.STRING_ARRAY) {
                _setStringArray(key, existingJson.readStringArray(pointer));
            } else if (expected == DataType.UINT_ARRAY) {
                _setUintArray(key, existingJson.readUintArray(pointer));
            } else if (expected == DataType.INT_ARRAY) {
                _setIntArray(key, existingJson.readIntArray(pointer));
            }
        }
        _suppressIncrementalPersistence = false;
    }

    function fromJson(string memory existingJson) public virtual {
        _fromJsonNoSave(existingJson);
        _save();
    }

    // ============ JSON Rendering ============

    function toJson() public returns (string memory) {
        uint256 keyCount = _dataKeys.length;
        if (keyCount == 0) {
            return "{}";
        }

        uint256 maxSegments = 1;
        for (uint256 i = 0; i < keyCount; i++) {
            maxSegments += _dataKeys[i].split(".").length;
        }

        TempNode[] memory nodes = new TempNode[](maxSegments);
        nodes[0].parent = type(uint256).max;
        uint256 nodeCount = 1;

        for (uint256 i = 0; i < keyCount; i++) {
            string memory key = _dataKeys[i];
            if (!_hasKey[key]) {
                continue;
            }
            string[] memory segments = key.split(".");
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
            DataType valueType = keyType(key);
            if (valueType != DataType.OBJECT) {
                nodes[current].hasValue = true;
                nodes[current].valueJson = _encodeValue(key, valueType);
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

    function _findChild(
        TempNode[] memory nodes,
        uint256 nodeCount,
        uint256 parent,
        string memory name
    ) private pure returns (uint256) {
        for (uint256 i = 1; i < nodeCount; i++) {
            if (nodes[i].parent == parent && nodes[i].name.eq(name)) {
                return i;
            }
        }
        return type(uint256).max;
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
