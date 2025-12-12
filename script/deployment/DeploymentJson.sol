// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoFactory} from "@bao-factory/BaoFactory.sol";
import {DeploymentKeys, DataType, KeyPattern} from "@bao-script/deployment/DeploymentKeys.sol";

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O and serialization
 * @dev Extends DeploymentBase with:
 *      - JSON file path resolution (input/output)
 *      - Timestamp-based file naming
 *      - JSON serialization/deserialization (merged from DeploymentDataJson)
 *      - Production BaoFactory operator verification
 *
 *      Note: This extends DeploymentBase (not Deployment) to enable mixin pattern.
 *      Concrete classes must provide _ensureBaoFactory() via a mixin or direct implementation.
 *
 * This file is structured in two sections for easy verification:
 * 1. FROM DeploymentJson.sol - File I/O, path resolution, lifecycle
 * 2. FROM DeploymentDataJson.sol - JSON serialization/deserialization
 */
abstract contract DeploymentJson is DeploymentBase {
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
    bool private _suppressPersistence = false;

    constructor(uint256 time) {
        _filename = _formatTimestamp(time);
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
        if (!_suppressPersistence) {
            VM.createDir(_getOutputConfigDir(), true); // recursive=true, creates parent dirs if needed
            string memory json = toJson();
            VM.writeJson(json, _getOutputConfigPath());
            // Also write to latest.json for easy tracking during deployment
            if (_saveLatestLogToo()) {
                VM.writeJson(json, string.concat(_getOutputConfigDir(), "/latest.json"));
            }
        }
    }

    function _saveLatestLogToo() internal pure virtual returns (bool) {
        return true;
    }

    function _disableLogging() internal {
        _suppressPersistence = true;
    }

    function _disableIncrementalLogging() internal {
        _suppressIncrementalPersistence = true;
    }

    function _saveDeployment() internal {
        _save();
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

    function _getConfigPath() internal returns (string memory) {
        return string.concat(_getRoot(), "/", _systemSaltString, ".json");
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

    /// @dev Look up source path by scanning artifacts and matching creation bytecode
    /// @param contractType The contract name to search for
    /// @param creationCode The contract's creation bytecode from type(Contract).creationCode for disambiguation
    function _lookupContractPath(
        string memory contractType,
        bytes memory creationCode
    ) internal view virtual override returns (string memory contractPath) {
        // Skip expensive directory iteration during coverage runs
        // This ensures consistent coverage metrics regardless of out/ directory state
        try VM.envBool("BAO_COVERAGE_RUN") returns (bool isCoverage) {
            if (isCoverage) {
                return "";
            }
        } catch {}

        string memory outDir = string.concat(VM.projectRoot(), "/out");
        string memory targetFilename = string.concat(contractType, ".json");

        Vm.DirEntry[] memory entries = VM.readDir(outDir, 3);
        string[] memory artifactJsons = new string[](entries.length);
        string[] memory sourcePaths = new string[](entries.length);
        uint256 candidateCount;

        for (uint256 i = 0; i < entries.length; i++) {
            string memory path = entries[i].path;
            if (!path.endsWith(targetFilename)) continue;

            string memory json = VM.readFile(path);
            string[] memory keys = VM.parseJsonKeys(json, ".metadata.settings.compilationTarget");
            if (keys.length == 0) continue;

            artifactJsons[candidateCount] = json;
            sourcePaths[candidateCount] = keys[0];
            candidateCount++;
        }

        if (candidateCount == 0) {
            return string.concat(contractType, ": no matching artifact found");
        }

        if (candidateCount == 1) {
            return sourcePaths[0];
        }

        string[] memory uniquePaths = new string[](candidateCount);
        uint256 uniqueCount;
        for (uint256 i = 0; i < candidateCount; i++) {
            bool duplicate;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (keccak256(bytes(uniquePaths[j])) == keccak256(bytes(sourcePaths[i]))) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            uniquePaths[uniqueCount] = sourcePaths[i];
            uniqueCount++;
        }

        if (creationCode.length == 0) {
            return _formatCandidatePaths(uniquePaths, uniqueCount);
        }

        bytes32 targetHash = keccak256(creationCode);
        for (uint256 i = 0; i < candidateCount; i++) {
            try VM.parseJsonBytes(artifactJsons[i], ".bytecode.object") returns (bytes memory artifactCode) {
                if (keccak256(artifactCode) == targetHash) {
                    return sourcePaths[i];
                }
            } catch {
                return _formatCandidatePaths(uniquePaths, uniqueCount);
            }
        }

        return _formatCandidatePaths(uniquePaths, uniqueCount);
    }

    function _formatCandidatePaths(string[] memory paths, uint256 count) private pure returns (string memory) {
        string memory joined;
        for (uint256 i = 0; i < count; i++) {
            if (bytes(paths[i]).length == 0) continue;
            if (bytes(joined).length == 0) {
                joined = paths[i];
            } else {
                joined = string.concat(joined, " | ", paths[i]);
            }
        }
        return joined;
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
    /// @param startPoint Start point for input resolution ("first", "latest", or timestamp)
    function _beforeStart(
        string memory network_,
        string memory systemSaltString_,
        string memory startPoint
    ) internal virtual override {
        _requireNetwork(network_);
        require(bytes(systemSaltString_).length > 0, "cannot have a null system salt string");

        _network = network_;
        _systemSaltString = systemSaltString_;

        // Load initial data from the specified file
        string memory path;
        if (bytes(startPoint).length == 0 || startPoint.eq("first")) {
            path = _getConfigPath();
        } else if (startPoint.eq("latest")) {
            path = _findLatestFile();
        } else {
            path = string.concat(_getOutputConfigDir(), "/", startPoint, ".json");
        }
        require(VM.exists(path), string.concat("startPoint file does not exist: ", path));
        fromJson(VM.readFile(path));
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

    /// @notice Resolve a string value that may be a JSON pointer reference
    /// @dev If the value starts with "$.", treat it as a JSON pointer and resolve it
    /// @param existingJson The JSON document to resolve references against
    /// @param value The string value that may be a reference
    /// @return The resolved value (original if not a reference)
    function _resolveReference(string memory existingJson, string memory value) private pure returns (string memory) {
        if (value.startsWith("$.")) {
            return existingJson.readString(value);
        }
        return value;
    }

    /// @notice Resolve an array of string values that may contain JSON pointer references
    /// @param existingJson The JSON document to resolve references against
    /// @param values The string array that may contain references
    /// @return resolved The array with all references resolved
    function _resolveReferences(
        string memory existingJson,
        string[] memory values
    ) private pure returns (string[] memory resolved) {
        resolved = new string[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            resolved[i] = _resolveReference(existingJson, values[i]);
        }
    }

    function _fromJsonNoSave(string memory existingJson) internal {
        if (bytes(existingJson).length == 0) {
            return;
        }

        bool previousSuppressIncrementalPersistence = _suppressIncrementalPersistence;
        _suppressIncrementalPersistence = true; // we don't want the loading to write out each change, on loading

        // Expand patterns - for each pattern (prefix.*.suffix), find matching keys in JSON and register them
        // TODO: remove patterns() it just returns _patterns
        for (uint256 p = 0; p < _patterns.length; p++) {
            KeyPattern memory pat = _patterns[p];
            string memory prefixPointer = string.concat("$.", pat.prefix);

            // Check if prefix exists in JSON
            if (!existingJson.keyExists(prefixPointer)) {
                continue;
            }

            // Get children of prefix using parseJsonKeys
            string[] memory children;
            try VM.parseJsonKeys(existingJson, prefixPointer) returns (string[] memory keys) {
                children = keys;
            } catch {
                continue; // Not an object, skip
            }

            // For each child, check if child.suffix exists and register the concrete key
            for (uint256 c = 0; c < children.length; c++) {
                string memory child = children[c];
                string memory concreteKey = string.concat(pat.prefix, ".", child, ".", pat.suffix);
                string memory concretePointer = string.concat("$.", concreteKey);

                if (existingJson.keyExists(concretePointer)) {
                    // Register intermediate object (prefix.child) - _registerKeyFromPattern is idempotent
                    string memory intermediateKey = string.concat(pat.prefix, ".", child);
                    _registerKeyFromPattern(
                        intermediateKey,
                        KeyPattern({prefix: pat.prefix, suffix: child, dtype: DataType.OBJECT, decimals: DECIMALS_AUTO})
                    );
                    // Register the concrete key
                    _registerKeyFromPattern(concreteKey, pat);
                }
            }
        }

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
                // Store raw string (either "0x..." literal or key reference) - resolution happens on read
                string memory rawValue = existingJson.readString(pointer);
                _setAddressFromString(key, rawValue);
            } else if (expected == DataType.STRING) {
                string memory rawValue = existingJson.readString(pointer);
                _setString(key, _resolveReference(existingJson, rawValue));
            } else if (expected == DataType.UINT) {
                _setUint(key, existingJson.readUint(pointer));
            } else if (expected == DataType.INT) {
                _setInt(key, existingJson.readInt(pointer));
            } else if (expected == DataType.BOOL) {
                _setBool(key, existingJson.readBool(pointer));
            } else if (expected == DataType.ADDRESS_ARRAY) {
                // Store raw string array - resolution happens on read
                _setAddressArrayFromStrings(key, existingJson.readStringArray(pointer));
            } else if (expected == DataType.STRING_ARRAY) {
                string[] memory rawValues = existingJson.readStringArray(pointer);
                _setStringArray(key, _resolveReferences(existingJson, rawValues));
            } else if (expected == DataType.UINT_ARRAY) {
                _setUintArray(key, existingJson.readUintArray(pointer));
            } else if (expected == DataType.INT_ARRAY) {
                _setIntArray(key, existingJson.readIntArray(pointer));
            }
        }

        _suppressIncrementalPersistence = previousSuppressIncrementalPersistence;
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
            return _encodeAddressKey(key);
        }
        if (valueType == DataType.STRING) {
            return _encodeStringValue(_strings[key]);
        }
        if (valueType == DataType.UINT) {
            return _encodeNumeric(_uints[key], _keyDecimals[key]);
        }
        if (valueType == DataType.INT) {
            return _encodeNumeric(_ints[key], _keyDecimals[key]);
        }
        if (valueType == DataType.BOOL) {
            return _bools[key] ? "true" : "false";
        }
        if (valueType == DataType.ADDRESS_ARRAY) {
            return _encodeAddressArrayKey(key);
        }
        if (valueType == DataType.STRING_ARRAY) {
            return _encodeStringArrayValue(_stringArrays[key]);
        }
        if (valueType == DataType.UINT_ARRAY) {
            return _encodeNumericArrayValue(_uintArrays[key], _keyDecimals[key]);
        }
        if (valueType == DataType.INT_ARRAY) {
            return _encodeNumericArrayValue(_intArrays[key], _keyDecimals[key]);
        }
        revert("DeploymentDataStore: unsupported type");
    }

    function _encodeAddressValue(address value) private pure returns (string memory) {
        return string.concat('"', LibString.toHexString(uint160(value), 20), '"');
    }

    /// @notice Encode address key with lenient resolution
    /// @dev Tries to resolve to actual address; falls back to raw string if lookup fails
    function _encodeAddressKey(string memory key) private view returns (string memory) {
        string memory raw = _getAddressRaw(key);
        (bool success, address resolved) = _tryResolveAddressValue(raw);
        if (success) {
            return _encodeAddressValue(resolved);
        }
        // Fallback: output the raw reference string
        return string.concat('"', raw, '"');
    }

    /// @notice Encode address array key with lenient resolution
    /// @dev Tries to resolve each element; falls back to raw string if lookup fails
    function _encodeAddressArrayKey(string memory key) private view returns (string memory) {
        string[] memory raw = _getAddressArrayRaw(key);
        if (raw.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < raw.length; i++) {
            (bool success, address resolved) = _tryResolveAddressValue(raw[i]);
            string memory encoded;
            if (success) {
                encoded = _encodeAddressValue(resolved);
            } else {
                // Fallback: output the raw reference string
                encoded = string.concat('"', raw[i], '"');
            }
            json = string.concat(json, i == 0 ? "" : ",", encoded);
        }
        return string.concat(json, "]");
    }

    function _encodeStringValue(string memory value) private returns (string memory) {
        string memory tmp = VM.serializeString("__bao_string", "value", value);
        return _extractSerializedValue(tmp);
    }

    // ============================================================================
    // Scientific Notation Encoding
    // ============================================================================
    //
    // Two modes controlled by decimals parameter from key registration:
    // 1. Fixed scale (decimals < DECIMALS_AUTO): For token amounts
    //    - _encodeNumeric(value, 18) → "1.5e18", "0.05e18"
    // 2. Auto exponent (decimals == DECIMALS_AUTO): For general numbers (printf %g style)
    //    - _encodeNumeric(value) → "123", "1.5e6", "1.23e12"
    //
    // ============================================================================

    /// @notice Threshold for auto-exponent mode (switch to scientific above this)
    /// @dev Default 1e6 means 1000000 stays decimal, 10000000 becomes 1e7
    function _autoExponentThreshold() internal pure virtual returns (uint256) {
        return 1e6;
    }

    /// @notice Minimum value threshold for fixed-exponent mode
    /// @dev Values below scale/threshold stay as plain decimals
    function _minScaledThreshold() internal pure virtual returns (uint256) {
        return 1e6; // Require at least 0.000001 of the unit
    }

    // ============ Core formatting (shared logic) ============

    /// @notice Format a value with a specific exponent
    /// @dev Core function used by both fixed and auto modes
    function _formatScientific(
        uint256 integerPart,
        uint256 fractionalPart,
        uint256 exponent,
        uint256 maxFractionalDigits
    ) private pure returns (string memory) {
        if (fractionalPart == 0) {
            return string.concat(LibString.toString(integerPart), "e", LibString.toString(exponent));
        }

        // Normalize fractional part by removing trailing zeros
        uint256 fractionalDigits = maxFractionalDigits;
        while (fractionalPart % 10 == 0 && fractionalDigits > 0) {
            fractionalPart /= 10;
            fractionalDigits--;
        }

        // Build fractional string with leading zeros if needed
        string memory fractionalStr = LibString.toString(fractionalPart);
        uint256 leadingZeros = fractionalDigits > bytes(fractionalStr).length
            ? fractionalDigits - bytes(fractionalStr).length
            : 0;

        string memory zeros = "";
        for (uint256 i = 0; i < leadingZeros; i++) {
            zeros = string.concat(zeros, "0");
        }

        return
            string.concat(
                LibString.toString(integerPart),
                ".",
                zeros,
                fractionalStr,
                "e",
                LibString.toString(exponent)
            );
    }

    // ============ Numeric Encoding (overloaded for uint256/int256) ============

    /// @notice Encode uint256 with auto exponent (printf %g style)
    /// @param value The value to encode
    /// @return "123", "1.5e6", "1.23e12", etc.
    function _encodeNumeric(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 threshold = _autoExponentThreshold();
        if (value < threshold) {
            return LibString.toString(value);
        }

        // Count digits inline
        uint8 digits = 0;
        {
            uint256 tmp = value;
            while (tmp > 0) {
                digits++;
                tmp /= 10;
            }
        }
        uint8 exponent = digits - 1;
        uint256 scale = 10 ** exponent;

        return _formatScientific(value / scale, value % scale, exponent, exponent);
    }

    /// @notice Encode uint256 with specified decimals
    /// @param value The raw value
    /// @param decimals The decimal scale, or DECIMALS_AUTO for auto mode
    /// @return Formatted string
    function _encodeNumeric(uint256 value, uint256 decimals) internal pure returns (string memory) {
        if (decimals == DECIMALS_AUTO) {
            return _encodeNumeric(value);
        }
        if (value == 0) return "0";
        if (decimals == 0) return LibString.toString(value);

        uint256 scale = 10 ** decimals;
        uint256 threshold = _minScaledThreshold();

        // Very small values stay as plain decimal
        if (threshold > 0 && value < scale / threshold) {
            return LibString.toString(value);
        }

        return _formatScientific(value / scale, value % scale, decimals, decimals);
    }

    /// @notice Encode int256 with auto exponent (printf %g style)
    function _encodeNumeric(int256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        bool negative = value < 0;
        uint256 absValue = negative ? uint256(-value) : uint256(value);
        string memory encoded = _encodeNumeric(absValue);

        return negative ? string.concat("-", encoded) : encoded;
    }

    /// @notice Encode int256 with specified decimals
    function _encodeNumeric(int256 value, uint256 decimals) internal pure returns (string memory) {
        if (value == 0) return "0";

        bool negative = value < 0;
        uint256 absValue = negative ? uint256(-value) : uint256(value);
        string memory encoded = _encodeNumeric(absValue, decimals);

        return negative ? string.concat("-", encoded) : encoded;
    }

    // ============ Array Encoding ============

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

    function _encodeNumericArrayValue(uint256[] storage values, uint256 decimals) private view returns (string memory) {
        if (values.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < values.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", _encodeNumeric(values[i], decimals));
        }
        return string.concat(json, "]");
    }

    function _encodeNumericArrayValue(int256[] storage values, uint256 decimals) private view returns (string memory) {
        if (values.length == 0) {
            return "[]";
        }
        string memory json = "[";
        for (uint256 i = 0; i < values.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", _encodeNumeric(values[i], decimals));
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
