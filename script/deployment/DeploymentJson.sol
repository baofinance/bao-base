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
     * @dev Updates finishedAt to current timestamp on each save
     */
    function saveToJson(string memory filepath) public virtual {
        _updateFinishedAt();
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
                    deploymentsJson = _serializeContractToObject(key);
                } else if (_eq(entryType, "proxy")) {
                    deploymentsJson = _serializeProxyToObject(key);
                } else if (_eq(entryType, "implementation")) {
                    deploymentsJson = _serializeImplementationToObject(key);
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

        // Serialize metadata
        string memory metadataJson = "";
        metadataJson = VM.serializeUint("metadata", "startedAt", _metadata.startedAt);
        if (_metadata.finishedAt > 0) {
            metadataJson = VM.serializeUint("metadata", "finishedAt", _metadata.finishedAt);
        }
        metadataJson = VM.serializeUint("metadata", "startBlock", _metadata.startBlock);
        metadataJson = VM.serializeString("metadata", "network", _metadata.network);
        metadataJson = VM.serializeString("metadata", "version", _metadata.version);
        string memory deployerJson = VM.serializeAddress("deployer", "address", _metadata.deployer);
        string memory ownerJson = VM.serializeAddress("owner", "address", _metadata.owner);

        // Build root JSON - serialize in order (last one finalizes)
        string memory rootJson = "";
        uint256 schemaVersion = _schemaVersion;
        if (schemaVersion == 0) {
            schemaVersion = DEPLOYMENT_SCHEMA_VERSION;
        }
        rootJson = VM.serializeUint("root", "schemaVersion", schemaVersion);
        rootJson = VM.serializeString("root", "metadata", metadataJson);
        rootJson = VM.serializeString("root", "deployer", deployerJson);
        rootJson = VM.serializeString("root", "owner", ownerJson);
        rootJson = VM.serializeString("root", "saltString", _metadata.systemSaltString);
        if (_keys.length > 0) {
            rootJson = VM.serializeString("root", "deployment", deploymentsJson);
        }

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
        if (_metadata.startedAt != 0) {
            revert AlreadyInitialized();
        }
        if (VM.keyExistsJson(json, ".schemaVersion")) {
            _schemaVersion = VM.parseJsonUint(json, ".schemaVersion");
        } else {
            _schemaVersion = DEPLOYMENT_SCHEMA_VERSION;
        }
        // Parse metadata
        _deserializeMetadata(json);

        // Get all keys from deployment object (if it exists)
        string[] memory loadedKeys;
        if (VM.keyExistsJson(json, ".deployment")) {
            loadedKeys = VM.parseJsonKeys(json, ".deployment");
        } else {
            // Empty deployment case - no entries to load
            loadedKeys = new string[](0);
        }

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
        json = VM.serializeString(key, "contractPath", info.contractPath);
        json = VM.serializeString(key, "contractType", info.contractType);
        json = VM.serializeAddress(key, "deployer", _metadata.deployer);
        json = VM.serializeAddress(key, "deployedTo", info.addr);
        json = VM.serializeAddress(key, "address", info.addr);
        json = VM.serializeUint(key, "blockNumber", info.blockNumber);

        if (info.txHash != bytes32(0)) {
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
        if (bytes(info.implementationKey).length > 0 && _exists[info.implementationKey]) {
            ImplementationEntry memory impl = _implementations[info.implementationKey];

            string memory implJson = "";
            implJson = VM.serializeString("implementation", "contractType", impl.info.contractType);
            implJson = VM.serializeString("implementation", "contractPath", impl.info.contractPath);
            implJson = VM.serializeAddress("implementation", "address", impl.info.addr);

            json = VM.serializeString(key, "implementation", implJson);
        }
        return json;
    }

    function _serializeProxiesArray(
        string memory key,
        string[] memory proxies,
        string memory json
    ) internal returns (string memory) {
        if (proxies.length > 0) {
            string memory proxiesJson = "";
            for (uint256 i = 0; i < proxies.length; i++) {
                proxiesJson = VM.serializeString("proxies", VM.toString(i), proxies[i]);
            }
            json = VM.serializeString(key, "proxies", proxiesJson);
        }
        return json;
    }

    // ============================================================================
    // Entry Serializers - Compose from reusable serializers
    // ============================================================================

    function _serializeContractToObject(string memory key) private returns (string memory) {
        ContractEntry memory entry = _contracts[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);

        return VM.serializeString("deployment", key, entryJson);
    }

    function _serializeProxyToObject(string memory key) private returns (string memory) {
        ProxyEntry memory entry = _proxies[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);
        entryJson = _serializeCREATE3Info(key, entry.create3, entryJson);
        entryJson = _serializeProxyInfo(key, entry.proxy, entryJson);

        return VM.serializeString("deployment", key, entryJson);
    }

    function _serializeLibraryToObject(string memory key) private returns (string memory) {
        LibraryEntry memory entry = _libraries[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);

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

    function _serializeImplementationToObject(string memory key) private returns (string memory) {
        ImplementationEntry memory entry = _implementations[key];

        string memory entryJson = "";
        entryJson = _serializeDeploymentInfo(key, entry.info, entryJson);
        entryJson = _serializeProxiesArray(key, entry.proxies, entryJson);

        return VM.serializeString("deployment", key, entryJson);
    }

    // ============================================================================
    // JSON Deserialization
    // ============================================================================

    function _deserializeMetadata(string memory json) private {
        _metadata.deployer = VM.parseJsonAddress(json, ".deployer.address");
        _metadata.owner = VM.parseJsonAddress(json, ".owner.address");
        _metadata.startedAt = VM.parseJsonUint(json, ".metadata.startedAt");
        _metadata.startBlock = VM.parseJsonUint(json, ".metadata.startBlock");
        _metadata.network = VM.parseJsonString(json, ".metadata.network");
        _metadata.version = VM.parseJsonString(json, ".metadata.version");
        _metadata.systemSaltString = VM.parseJsonString(json, ".saltString");
        _metadata.finishedAt = VM.parseJsonUint(json, ".metadata.finishedAt");
    }

    function _deserializeContract(string memory json, string memory key) private {
        string memory basePath = string.concat(".deployment.", key);

        DeploymentInfo memory info;
        info.addr = VM.parseJsonAddress(json, string.concat(basePath, ".address"));
        info.contractType = VM.parseJsonString(json, string.concat(basePath, ".contractType"));
        info.contractPath = VM.parseJsonString(json, string.concat(basePath, ".contractPath"));
        info.txHash = bytes32(0); // Not available when deserializing from JSON
        info.blockNumber = VM.parseJsonUint(json, string.concat(basePath, ".blockNumber"));
        info.category = VM.parseJsonString(json, string.concat(basePath, ".category"));

        _contracts[key] = ContractEntry({info: info});

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

        _proxies[key] = ProxyEntry({info: info, create3: create3Info, proxy: ProxyInfo({implementationKey: ""})});
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

        _libraries[key] = LibraryEntry({info: info});
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
    // Auto-save Support
    // ============================================================================

    /**
     * @notice Derive filepath from system salt
     * @return Path where JSON should be saved
     */
    function _filepath() internal view returns (string memory) {
        return string.concat("results/deployments/", _metadata.systemSaltString, ".json");
    }

    /**
     * @notice Auto-save deployment state to JSON
     * @dev Called after every mutation to keep JSON in sync
     */
    function _autoSave() internal {
        saveToJson(_filepath());
    }
}
