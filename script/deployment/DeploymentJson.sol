// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentRegistry} from "./DeploymentRegistry.sol";

/// @dev Foundry VM for JSON operations
Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/**
 * @title DeploymentJson
 * @notice JSON persistence mixin for Foundry-based deployments
 * @dev FOUNDRY-ONLY: This contract uses Foundry's VM cheat codes for JSON operations
 * @dev Usage: Mix into Foundry test contracts to add JSON persistence
 * @dev Example: contract MyTest is Deployment, DeploymentJson { }
 * @dev Wake deployments: DO NOT inherit from this - use Python for state management
 */
abstract contract DeploymentJson is DeploymentRegistry {
    // ============================================================================
    // JSON Public API
    // ============================================================================

    /**
     * @notice Save deployment to JSON file
     * @param filepath Path to write JSON file
     * @dev Updates finishTimestamp to current timestamp on each save
     * @dev Creates parent directory structure if it doesn't exist
     */
    function saveToJson(string memory filepath) public virtual {
        _updateFinishedAt();
        // Create directory structure based on whether network subdirs are used
        string memory dir;
        if (_useNetworkSubdir()) {
            dir = string.concat(_getBaseDirPrefix(), "deployments/", _metadata.network);
        } else {
            dir = string.concat(_getBaseDirPrefix(), "deployments");
        }
        VM.createDir(dir, true);
        VM.writeJson(toJson(), filepath);
    }

    /**
     * @notice Serialize deployment to JSON string (without writing to file)
     * @dev Useful for tests to avoid littering filesystem
     * @return JSON string representation of the deployment
     */
    function toJson() public virtual returns (string memory) {
        // Serialize all entries and capture final JSON
        string memory deploymentsJson = "";
        if (_keys.length > 0) {
            for (uint256 i = 0; i < _keys.length; i++) {
                string memory key = _keys[i];
                string memory entryType = _entryType[key];

                if (_eq(entryType, "contract")) {
                    deploymentsJson = _serializeContractToObject(key, false);
                } else if (_eq(entryType, "proxy")) {
                    deploymentsJson = _serializeProxyToObject(key);
                } else if (_eq(entryType, "implementation")) {
                    deploymentsJson = _serializeContractToObject(key, true); // Include proxies array
                } else if (_eq(entryType, "library")) {
                    deploymentsJson = _serializeLibraryToObject(key);
                } else if (
                    _eq(entryType, "string") ||
                    _eq(entryType, "uint256") ||
                    _eq(entryType, "int256") ||
                    _eq(entryType, "bool")
                ) {
                    deploymentsJson = _serializeParameterToObject(key);
                }
            }
        }

        // Build root JSON with flattened metadata - serialize in order (last one finalizes)
        string memory rootJson = "";
        uint256 schemaVersion = _schemaVersion;
        if (schemaVersion == 0) {
            schemaVersion = DEPLOYMENT_SCHEMA_VERSION;
        }
        rootJson = VM.serializeUint("root", "schemaVersion", schemaVersion);
        rootJson = VM.serializeAddress("root", "deployer", _metadata.deployer);
        rootJson = VM.serializeAddress("root", "owner", _metadata.owner);
        rootJson = VM.serializeString("root", "saltString", _metadata.systemSaltString);
        rootJson = VM.serializeString("root", "network", _metadata.network);
        rootJson = VM.serializeString("root", "version", _metadata.version);

        // Always include deployment field (empty object if no entries)
        rootJson = VM.serializeString("root", "deployment", _keys.length > 0 ? deploymentsJson : "{}");

        // Inject runs array AFTER all VM.serialize calls (they would overwrite manual injection)
        rootJson = _serializeRunsToRoot(rootJson);

        return rootJson;
    }

    /**
     * @notice Load deployment from JSON file
     * @param filepath Path to JSON file to load
     */
    function loadFromJson(string memory filepath) public virtual {
        fromJson(VM.readFile(filepath));
    }

    /**
     * @notice Load deployment from JSON string (without reading from file)
     * @dev Useful for tests to avoid littering filesystem
     * @param json JSON string to parse
     */
    function fromJson(string memory json) public virtual {
        if (_metadata.startTimestamp != 0) {
            revert AlreadyInitialized();
        }
        if (VM.keyExistsJson(json, ".schemaVersion")) {
            _schemaVersion = VM.parseJsonUint(json, ".schemaVersion");
        } else {
            _schemaVersion = DEPLOYMENT_SCHEMA_VERSION;
        }
        // Parse metadata
        _deserializeMetadata(json);

        // Get all keys from deployment object
        string[] memory loadedKeys = VM.parseJsonKeys(json, ".deployment");

        for (uint256 i = 0; i < loadedKeys.length; i++) {
            string memory key = loadedKeys[i];

            // Check if it's a parameter first (has .type field)
            if (VM.keyExistsJson(json, string.concat(".deployment.", key, ".type"))) {
                _deserializeParameter(json, key);
            } else {
                // Otherwise check category for contract types
                string memory category = VM.parseJsonString(json, string.concat(".deployment.", key, ".category"));

                if (_eq(category, "UUPS proxy")) {
                    _deserializeProxy(json, key);
                } else if (_eq(category, "library")) {
                    _deserializeLibrary(json, key);
                } else {
                    _deserializeContract(json, key);
                }
            }
        }

        // Post-processing: mark contracts that have proxies as implementations
        for (uint256 i = 0; i < loadedKeys.length; i++) {
            string memory key = loadedKeys[i];
            if (_eq(_entryType[key], "contract")) {
                // Check if any proxy uses this as implementation
                for (uint256 j = 0; j < loadedKeys.length; j++) {
                    if (
                        _eq(_entryType[loadedKeys[j]], "proxy") &&
                        _eq(_proxies[loadedKeys[j]].proxy.implementationKey, key)
                    ) {
                        _entryType[key] = "implementation";
                        break;
                    }
                }
            }
        }
    }

    // ============================================================================
    // JSON Serialization - Reusable Component Serializers
    // ============================================================================

    function _serializeDeploymentInfo(
        string memory key,
        DeploymentInfo memory info,
        string memory json
    ) internal returns (string memory) {
        json = VM.serializeString(key, "category", info.category);

        // For existing contracts, only include address and blockNumber
        bool isExisting = _eq(info.category, "existing");

        if (!isExisting) {
            json = VM.serializeString(key, "contractPath", info.contractPath);
            json = VM.serializeString(key, "contractType", info.contractType);
            json = VM.serializeAddress(key, "deployer", _metadata.deployer);
            json = VM.serializeAddress(key, "deployedTo", info.addr);
        }

        json = VM.serializeAddress(key, "address", info.addr);
        json = VM.serializeUint(key, "blockNumber", info.blockNumber);

        if (!isExisting && info.txHash != bytes32(0)) {
            json = VM.serializeBytes32(key, "transactionHash", info.txHash);
        }

        return json;
    }

    function _serializeCREATE3Info(
        string memory key,
        Create3Info memory info,
        string memory json
    ) internal returns (string memory) {
        json = VM.serializeString(key, "proxyType", info.proxyType);
        json = VM.serializeString(key, "saltString", info.saltString);
        json = VM.serializeBytes32(key, "salt", info.salt);
        return json;
    }

    function _serializeProxyInfo(
        string memory key,
        ProxyInfo memory info,
        string memory json
    ) internal returns (string memory) {
        if (bytes(info.implementationKey).length > 0) {
            json = VM.serializeString(key, "implementationKey", info.implementationKey);
        }
        return json;
    }

    /**
     * @dev Build proxies array for an implementation by iterating through all proxies
     * @param implementationKey The key of the implementation contract
     * @return Array of proxy keys that use this implementation
     */
    function _buildProxiesArray(string memory implementationKey) private view returns (string[] memory) {
        // Count proxies that use this implementation
        uint256 count = 0;
        for (uint256 i = 0; i < _keys.length; i++) {
            if (_eq(_entryType[_keys[i]], "proxy")) {
                if (_eq(_proxies[_keys[i]].proxy.implementationKey, implementationKey)) {
                    count++;
                }
            }
        }

        // Build array
        string[] memory proxies = new string[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _keys.length; i++) {
            if (_eq(_entryType[_keys[i]], "proxy")) {
                if (_eq(_proxies[_keys[i]].proxy.implementationKey, implementationKey)) {
                    proxies[index++] = _keys[i];
                }
            }
        }

        return proxies;
    }

    // ============================================================================
    // Entry Serializers - Compose from reusable serializers
    // ============================================================================

    function _serializeContractToObject(string memory key, bool isImplementation) private returns (string memory) {
        ContractEntry memory entry = _contracts[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);

        // Add factory (if CREATE3) and deployer (executor) - skip deployer for existing contracts
        bool isExisting = _eq(entry.info.category, "existing");
        if (entry.factory != address(0)) {
            entryJson = VM.serializeAddress(key, "factory", entry.factory);
        }
        if (!isExisting && entry.deployer != address(0)) {
            entryJson = VM.serializeAddress(key, "deployer", entry.deployer);
        }

        // Build proxies array dynamically for implementations
        if (isImplementation) {
            string[] memory proxies = _buildProxiesArray(key);
            // Always serialize the array, even if empty, to ensure it overwrites any previous value
            entryJson = VM.serializeString(key, "proxies", proxies);
        }

        return VM.serializeString("deployment", key, entryJson);
    }

    function _serializeProxyToObject(string memory key) private returns (string memory) {
        ProxyEntry memory entry = _proxies[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);
        entryJson = _serializeCREATE3Info(key, entry.create3, entryJson);
        entryJson = _serializeProxyInfo(key, entry.proxy, entryJson);

        // Add factory and deployer (executor)
        entryJson = VM.serializeAddress(key, "factory", entry.factory);
        entryJson = VM.serializeAddress(key, "deployer", entry.deployer);

        return VM.serializeString("deployment", key, entryJson);
    }

    function _serializeLibraryToObject(string memory key) private returns (string memory) {
        LibraryEntry memory entry = _libraries[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);

        // Add deployer (executor)
        entryJson = VM.serializeAddress(key, "deployer", entry.deployer);

        return VM.serializeString("deployment", key, entryJson);
    }

    function _serializeParameterToObject(string memory key) private returns (string memory) {
        string memory paramType = _entryType[key];
        string memory entryJson = "";

        // Always serialize type first
        entryJson = VM.serializeString(key, "type", paramType);

        if (_eq(paramType, "string")) {
            entryJson = VM.serializeString(key, "value", _stringParams[key]);
        } else if (_eq(paramType, "uint256")) {
            entryJson = VM.serializeUint(key, "value", _uintParams[key]);
        } else if (_eq(paramType, "int256")) {
            entryJson = VM.serializeInt(key, "value", _intParams[key]);
        } else if (_eq(paramType, "bool")) {
            entryJson = VM.serializeBool(key, "value", _boolParams[key]);
        }

        return VM.serializeString("deployment", key, entryJson);
    }

    // ============================================================================
    // JSON Deserialization
    // ============================================================================

    function _deserializeMetadata(string memory json) private {
        _metadata.deployer = VM.parseJsonAddress(json, ".deployer");
        _metadata.owner = VM.parseJsonAddress(json, ".owner");
        _metadata.network = VM.parseJsonString(json, ".network");
        _metadata.version = VM.parseJsonString(json, ".version");
        _metadata.systemSaltString = VM.parseJsonString(json, ".saltString");

        // Load runs array - must exist for valid deployment
        require(VM.keyExistsJson(json, ".runs"), "Missing runs array in JSON");
        require(VM.keyExistsJson(json, ".runs[0]"), "Empty runs array in JSON");

        // Count runs by trying to access increasing indices
        uint256 runCount = 0;
        while (VM.keyExistsJson(json, string.concat(".runs[", VM.toString(runCount), "]"))) {
            runCount++;
        }

        // Parse each run manually (avoiding ISO fields which aren't in struct)
        for (uint256 i = 0; i < runCount; i++) {
            string memory runPath = string.concat(".runs[", VM.toString(i), "]");
            RunRecord memory run;
            run.deployer = VM.parseJsonAddress(json, string.concat(runPath, ".deployer"));
            run.startTimestamp = VM.parseJsonUint(json, string.concat(runPath, ".startTimestamp"));
            run.startBlock = VM.parseJsonUint(json, string.concat(runPath, ".startBlock"));
            run.finished = VM.parseJsonBool(json, string.concat(runPath, ".finished"));
            if (VM.keyExistsJson(json, string.concat(runPath, ".finishTimestamp"))) {
                run.finishTimestamp = VM.parseJsonUint(json, string.concat(runPath, ".finishTimestamp"));
            }
            if (VM.keyExistsJson(json, string.concat(runPath, ".finishBlock"))) {
                run.finishBlock = VM.parseJsonUint(json, string.concat(runPath, ".finishBlock"));
            }
            _runs.push(run);
        }

        // Validate runs for resume
        require(_runs.length >= 1, "Cannot resume: no runs in deployment");
        require(_runs[_runs.length - 1].finished, "Cannot resume: last run not finished");

        _metadata.startTimestamp = _runs[0].startTimestamp;
        _metadata.startBlock = _runs[0].startBlock;
        _metadata.finishTimestamp = _runs[_runs.length - 1].finishTimestamp;
        _metadata.finishBlock = _runs[_runs.length - 1].finishBlock;

        // Create new run record for this resume
        _runs.push(
            RunRecord({
                deployer: address(this),
                startTimestamp: block.timestamp,
                finishTimestamp: 0,
                startBlock: block.number,
                finishBlock: 0,
                finished: false
            })
        );
    }

    function _deserializeContract(string memory json, string memory key) private {
        string memory basePath = string.concat(".deployment.", key);

        DeploymentInfo memory info;
        info.addr = VM.parseJsonAddress(json, string.concat(basePath, ".address"));
        info.blockNumber = VM.parseJsonUint(json, string.concat(basePath, ".blockNumber"));
        info.category = VM.parseJsonString(json, string.concat(basePath, ".category"));

        // Only parse these fields for non-existing contracts
        bool isExisting = _eq(info.category, "existing");
        if (!isExisting) {
            info.contractType = VM.parseJsonString(json, string.concat(basePath, ".contractType"));
            info.contractPath = VM.parseJsonString(json, string.concat(basePath, ".contractPath"));
        } else {
            // Set defaults for existing contracts
            info.contractType = "ExistingContract";
            info.contractPath = "blockchain";
        }
        info.txHash = bytes32(0); // Not available when deserializing from JSON

        // Parse factory (CREATE3) and deployer (executor) - deployer is optional for existing contracts
        address factory = address(0);
        if (VM.keyExistsJson(json, string.concat(basePath, ".factory"))) {
            factory = VM.parseJsonAddress(json, string.concat(basePath, ".factory"));
        }
        address deployer = address(0);
        if (!isExisting && VM.keyExistsJson(json, string.concat(basePath, ".deployer"))) {
            deployer = VM.parseJsonAddress(json, string.concat(basePath, ".deployer"));
        }

        _contracts[key] = ContractEntry({info: info, factory: factory, deployer: deployer});

        _exists[key] = true;
        _entryType[key] = "contract";
        _keys.push(key);
    }

    function _deserializeProxy(string memory json, string memory key) private {
        string memory basePath = string.concat(".deployment.", key);

        DeploymentInfo memory info;
        info.addr = VM.parseJsonAddress(json, string.concat(basePath, ".address"));
        info.contractType = VM.parseJsonString(json, string.concat(basePath, ".contractType"));
        info.contractPath = VM.parseJsonString(json, string.concat(basePath, ".contractPath"));
        info.txHash = bytes32(0); // Not available when deserializing from JSON
        info.blockNumber = VM.parseJsonUint(json, string.concat(basePath, ".blockNumber"));
        info.category = VM.parseJsonString(json, string.concat(basePath, ".category"));

        Create3Info memory create3Info;
        create3Info.salt = VM.parseJsonBytes32(json, string.concat(basePath, ".salt"));
        create3Info.saltString = VM.parseJsonString(json, string.concat(basePath, ".saltString"));
        string memory proxyTypePath = string.concat(basePath, ".proxyType");
        if (VM.keyExistsJson(json, proxyTypePath)) {
            create3Info.proxyType = VM.parseJsonString(json, proxyTypePath);
        }

        ProxyInfo memory proxyInfo;
        string memory implKeyPath = string.concat(basePath, ".implementationKey");
        if (VM.keyExistsJson(json, implKeyPath)) {
            proxyInfo.implementationKey = VM.parseJsonString(json, implKeyPath);
        }

        // Parse factory (CREATE3 - always present for proxies) and deployer (executor)
        address factory = VM.parseJsonAddress(json, string.concat(basePath, ".factory"));
        address deployer = VM.parseJsonAddress(json, string.concat(basePath, ".deployer"));

        _proxies[key] = ProxyEntry({
            info: info,
            create3: create3Info,
            proxy: proxyInfo,
            factory: factory,
            deployer: deployer
        });
        _exists[key] = true;
        _entryType[key] = "proxy";
        _keys.push(key);
        _resumedProxies[key] = true;
    }

    function _deserializeLibrary(string memory json, string memory key) private {
        string memory basePath = string.concat(".deployment.", key);

        DeploymentInfo memory info;
        info.addr = VM.parseJsonAddress(json, string.concat(basePath, ".address"));
        info.contractType = VM.parseJsonString(json, string.concat(basePath, ".contractType"));
        info.contractPath = VM.parseJsonString(json, string.concat(basePath, ".contractPath"));
        info.blockNumber = VM.parseJsonUint(json, string.concat(basePath, ".blockNumber"));
        info.category = VM.parseJsonString(json, string.concat(basePath, ".category"));

        // Parse deployer (executor)
        address deployer = VM.parseJsonAddress(json, string.concat(basePath, ".deployer"));

        _libraries[key] = LibraryEntry({info: info, deployer: deployer});
        _exists[key] = true;
        _entryType[key] = "library";
        _keys.push(key);
    }

    function _deserializeParameter(string memory json, string memory key) private {
        string memory basePath = string.concat(".deployment.", key);

        // Read type field explicitly
        string memory paramType = VM.parseJsonString(json, string.concat(basePath, ".type"));

        if (_eq(paramType, "string")) {
            _stringParams[key] = VM.parseJsonString(json, string.concat(basePath, ".value"));
            _exists[key] = true;
            _entryType[key] = "string";
            _keys.push(key);
        } else if (_eq(paramType, "uint256")) {
            _uintParams[key] = VM.parseJsonUint(json, string.concat(basePath, ".value"));
            _exists[key] = true;
            _entryType[key] = "uint256";
            _keys.push(key);
        } else if (_eq(paramType, "int256")) {
            _intParams[key] = VM.parseJsonInt(json, string.concat(basePath, ".value"));
            _exists[key] = true;
            _entryType[key] = "int256";
            _keys.push(key);
        } else if (_eq(paramType, "bool")) {
            _boolParams[key] = VM.parseJsonBool(json, string.concat(basePath, ".value"));
            _exists[key] = true;
            _entryType[key] = "bool";
            _keys.push(key);
        }
    }

    // ============================================================================
    // Timestamp Formatting
    // ============================================================================

    /**
     * @notice Convert Unix timestamp to ISO 8601 date-time string
     * @param timestamp Unix timestamp in seconds
     * @return ISO 8601 formatted string (YYYY-MM-DDTHH:MM:SSZ)
     */
    function _formatTimestamp(uint256 timestamp) internal pure returns (string memory) {
        if (timestamp == 0) return "";

        // Calculate date components
        uint256 z = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        y = m <= 2 ? y + 1 : y;

        // Calculate time components
        uint256 secondsInDay = timestamp % 86400;
        uint256 hour = secondsInDay / 3600;
        uint256 minute = (secondsInDay % 3600) / 60;
        uint256 second = secondsInDay % 60;

        // Format as ISO 8601: YYYY-MM-DDTHH:MM:SSZ
        return
            string(
                abi.encodePacked(
                    _padZero(y, 4),
                    "-",
                    _padZero(m, 2),
                    "-",
                    _padZero(d, 2),
                    "T",
                    _padZero(hour, 2),
                    ":",
                    _padZero(minute, 2),
                    ":",
                    _padZero(second, 2),
                    "Z"
                )
            );
    }

    /**
     * @notice Pad number with leading zeros
     * @param num Number to pad
     * @param width Target width
     * @return Padded string
     */
    function _padZero(uint256 num, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(VM.toString(num));
        if (b.length >= width) return string(b);

        bytes memory padded = new bytes(width);
        uint256 padLen = width - b.length;
        for (uint256 i = 0; i < padLen; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[padLen + i] = b[i];
        }
        return string(padded);
    }

    /**
     * @notice Serialize runs array for audit trail
     * @return JSON array of run records
     */
    function _serializeRunsToRoot(string memory rootJson) internal view returns (string memory) {
        // Build runs array as proper JSON array string
        string memory runsArrayStr = "[";
        for (uint256 i = 0; i < _runs.length; i++) {
            if (i > 0) runsArrayStr = string.concat(runsArrayStr, ",");

            // Build individual run object
            string memory runJson = "{";
            runJson = string.concat(runJson, '"deployer":"', VM.toString(_runs[i].deployer), '",');
            runJson = string.concat(runJson, '"startTimestamp":', VM.toString(_runs[i].startTimestamp), ",");
            runJson = string.concat(runJson, '"startTimestampISO":"', _formatTimestamp(_runs[i].startTimestamp), '",');
            if (_runs[i].finishTimestamp > 0) {
                runJson = string.concat(runJson, '"finishTimestamp":', VM.toString(_runs[i].finishTimestamp), ",");
                runJson = string.concat(
                    runJson,
                    '"finishTimestampISO":"',
                    _formatTimestamp(_runs[i].finishTimestamp),
                    '",'
                );
            }
            runJson = string.concat(runJson, '"startBlock":', VM.toString(_runs[i].startBlock), ",");
            if (_runs[i].finishBlock > 0) {
                runJson = string.concat(runJson, '"finishBlock":', VM.toString(_runs[i].finishBlock), ",");
            }
            runJson = string.concat(runJson, '"finished":', _runs[i].finished ? "true" : "false");
            runJson = string.concat(runJson, "}");

            runsArrayStr = string.concat(runsArrayStr, runJson);
        }
        runsArrayStr = string.concat(runsArrayStr, "]");

        // Manually inject the runs array into the root JSON
        // This is a workaround because VM.serialize* doesn't support proper arrays
        return _injectJsonField(rootJson, "runs", runsArrayStr, false);
    }

    function _injectJsonField(
        string memory json,
        string memory fieldName,
        string memory fieldValue,
        bool isString
    ) internal pure returns (string memory) {
        // Find the closing brace
        bytes memory jsonBytes = bytes(json);
        require(jsonBytes.length > 0 && jsonBytes[jsonBytes.length - 1] == "}", "Invalid JSON");

        // Remove closing brace
        string memory jsonWithoutClosing = _substring(json, 0, jsonBytes.length - 1);

        // Add comma if there's existing content (not just opening brace)
        string memory result = jsonWithoutClosing;
        if (jsonBytes.length > 2) {
            // More than just "{}"
            result = string.concat(result, ",");
        }

        // Add the field
        result = string.concat(result, '"', fieldName, '":');
        if (isString) {
            result = string.concat(result, '"', fieldValue, '"');
        } else {
            result = string.concat(result, fieldValue);
        }

        // Close the JSON
        result = string.concat(result, "}");

        return result;
    }

    function _substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    // ============================================================================
    // Auto-save Support
    // ============================================================================

    /**
     * @notice Get base directory prefix (empty for production, "results/" for tests)
     * @dev Override in test harness to return "results/"
     * @return Directory prefix (default: empty string for production)
     */
    function _getBaseDirPrefix() internal view virtual returns (string memory) {
        return "";
    }

    /**
     * @notice Check if network subdirectory should be used
     * @dev Override in test harness to return false for flat structure
     * @return True for production (use network subdir), false for tests (flat)
     */
    function _useNetworkSubdir() internal view virtual returns (bool) {
        return true;
    }

    /**
     * @notice Derive filepath from system salt and network
     * @return Path where JSON should be saved
     * @dev Production: deployments/{network}/{salt}.json
     * @dev Tests: results/deployments/{salt}.json
     */
    function _filepath() internal view returns (string memory) {
        if (_useNetworkSubdir()) {
            return
                string.concat(
                    _getBaseDirPrefix(),
                    "deployments/",
                    _metadata.network,
                    "/",
                    _metadata.systemSaltString,
                    ".json"
                );
        } else {
            return string.concat(_getBaseDirPrefix(), "deployments/", _metadata.systemSaltString, ".json");
        }
    }

    /**
     * @notice Save deployment state to registry JSON file
     * @dev Called after every mutation to keep JSON in sync with in-memory state
     * @dev Can be overridden in test harnesses to disable registry saves
     */
    function _saveToRegistry() internal virtual {
        saveToJson(_filepath());
    }
}
