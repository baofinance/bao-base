// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title DeploymentRegistry
 * @notice Pure storage layer for deployment tracking
 * @dev Design principles:
 *      - Pure data layer: storage structures + get/set operations
 *      - No deployment logic (that's in Deployment contract)
 *      - No JSON (that's in DeploymentJson mixin for Foundry)
 *      - Structured metadata with type-safe parameter storage
 *      - Dependency enforcement via get() errors
 *      - Platform agnostic: Works in both Foundry and Wake
 */
abstract contract DeploymentRegistry {
    // ============================================================================
    // Shared/Embedded Structs (for composition)
    // ============================================================================

    /// @notice Common fields for all deployed contracts
    struct DeploymentInfo {
        address addr;
        string contractType; // "Minter_v1", "MockERC20", etc.
        string contractPath; // "src/minter/Minter_v1.sol"
        bytes32 txHash;
        uint256 blockNumber;
        string category; // "contract", "proxy", "library", "mock", "existing"
    }

    /// @notice CREATE3-specific fields (deterministic deployment)
    struct Create3Info {
        bytes32 salt;
        string saltString; // Human-readable salt like "minter-v1"
    }

    /// @notice Proxy-specific fields
    struct ProxyInfo {
        string implementationKey; // Key to the implementation entry
    }

    // ============================================================================
    // Entry Types (compose from embedded structs)
    // ============================================================================

    /// @notice Top-level deployment metadata
    struct DeploymentMetadata {
        address deployer;
        uint256 startedAt;
        uint256 finishedAt;
        uint256 startBlock;
        string network;
        string version;
    }

    /// @notice Contract entry (direct deployment, mock, existing)
    struct ContractEntry {
        DeploymentInfo info;
    }

    /// @notice Proxy entry (always uses CREATE3)
    struct ProxyEntry {
        DeploymentInfo info;
        Create3Info create3;
        ProxyInfo proxy;
    }

    /// @notice Implementation entry (contract backing proxies)
    struct ImplementationEntry {
        DeploymentInfo info;
        string[] proxies; // Keys of proxies using this
    }

    /// @notice Library entry (always uses CREATE)
    struct LibraryEntry {
        DeploymentInfo info;
    }

    // ============================================================================
    // Events & Errors
    // ============================================================================

    event ContractDeployed(string indexed key, address indexed addr, string category);
    event ContractUpdated(string indexed key, address indexed oldAddr, address indexed newAddr);
    event ParameterSet(string indexed key, string valueType);

    error ContractNotFound(string key);
    error ContractAlreadyExists(string key);
    error LibraryAlreadyExists(string key);
    error ParameterNotFound(string key);
    error ParameterAlreadyExists(string key);
    error ParameterTypeMismatch(string key, string expected, string actual);
    error InvalidAddress(string key);
    error UnknownEntryType(string entrytype, string key);

    // ============================================================================
    // Storage
    // ============================================================================

    DeploymentMetadata internal _metadata;

    mapping(string => ContractEntry) internal _contracts;
    mapping(string => ProxyEntry) internal _proxies;
    mapping(string => ImplementationEntry) internal _implementations;
    mapping(string => LibraryEntry) internal _libraries;

    // Direct mappings for each parameter type (no struct wrappers)
    mapping(string => string) internal _stringParams;
    mapping(string => uint256) internal _uintParams;
    mapping(string => int256) internal _intParams;
    mapping(string => bool) internal _boolParams;

    mapping(string => bool) internal _exists;
    mapping(string => string) internal _entryType;
    string[] internal _keys;

    // ============================================================================
    // PUBLIC API - Registry Access
    // ============================================================================

    /**
     * @notice Get contract address (enforces dependencies)
     * @param key Contract identifier
     * @return addr Contract address
     * @dev Reverts with DependencyNotMet if contract not deployed
     * @dev Internal - external callers should use HarborDeployment's type-safe get(Contract)
     */
    function _get(string memory key) internal view returns (address) {
        if (!_exists[key]) {
            revert ContractNotFound(key);
        }

        string memory entryType = _entryType[key];

        if (_eq(entryType, "contract")) return _contracts[key].info.addr;
        if (_eq(entryType, "proxy")) return _proxies[key].info.addr;
        if (_eq(entryType, "implementation")) return _implementations[key].info.addr;
        if (_eq(entryType, "library")) return _libraries[key].info.addr;

        revert UnknownEntryType(entryType, key);
    }

    /**
     * @notice Check if contract is registered
     * @dev Internal - external callers should use HarborDeployment's type-safe has(Contract)
     */
    function _has(string memory key) internal view returns (bool) {
        return _exists[key];
    }

    // ============================================================================
    // Parameter Getters (overloaded by type)
    // ============================================================================

    /**
     * @notice Get string parameter (enforces dependencies)
     * @param key Parameter identifier
     * @return value The string value
     * @dev Reverts with ParameterNotFound if parameter not set
     */
    function _getString(string memory key) internal view returns (string memory) {
        if (!_exists[key]) {
            revert ParameterNotFound(key);
        }
        if (!_eq(_entryType[key], "string")) {
            revert ParameterTypeMismatch(key, "string", _entryType[key]);
        }
        return _stringParams[key];
    }

    /**
     * @notice Get uint256 parameter (enforces dependencies)
     * @param key Parameter identifier
     * @return value The uint256 value
     */
    function _getUint(string memory key) internal view returns (uint256) {
        if (!_exists[key]) {
            revert ParameterNotFound(key);
        }
        if (!_eq(_entryType[key], "uint256")) {
            revert ParameterTypeMismatch(key, "uint256", _entryType[key]);
        }
        return _uintParams[key];
    }

    /**
     * @notice Get int256 parameter (enforces dependencies)
     * @param key Parameter identifier
     * @return value The int256 value
     */
    function _getInt(string memory key) internal view returns (int256) {
        if (!_exists[key]) {
            revert ParameterNotFound(key);
        }
        if (!_eq(_entryType[key], "int256")) {
            revert ParameterTypeMismatch(key, "int256", _entryType[key]);
        }
        return _intParams[key];
    }

    /**
     * @notice Get bool parameter (enforces dependencies)
     * @param key Parameter identifier
     * @return value The bool value
     */
    function _getBool(string memory key) internal view returns (bool) {
        if (!_exists[key]) {
            revert ParameterNotFound(key);
        }
        if (!_eq(_entryType[key], "bool")) {
            revert ParameterTypeMismatch(key, "bool", _entryType[key]);
        }
        return _boolParams[key];
    }

    // ============================================================================
    // Parameter Setters
    // ============================================================================

    /**
     * @notice Set string parameter
     * @param key Parameter identifier
     * @param value The string value
     */
    function _setString(string memory key, string memory value) internal {
        _setStringParam(key, value);
    }

    /**
     * @notice Set uint256 parameter
     * @param key Parameter identifier
     * @param value The uint256 value
     */
    function _setUint(string memory key, uint256 value) internal {
        _setUintParam(key, value);
    }

    /**
     * @notice Set int256 parameter
     * @param key Parameter identifier
     * @param value The int256 value
     */
    function _setInt(string memory key, int256 value) internal {
        _setIntParam(key, value);
    }

    /**
     * @notice Set bool parameter
     * @param key Parameter identifier
     * @param value The bool value
     */
    function _setBool(string memory key, bool value) internal {
        _setBoolParam(key, value);
    }

    /**
     * @notice Get all registered keys
     */
    function keys() public view returns (string[] memory) {
        return _keys;
    }

    /**
     * @notice Get entry type for a key
     */
    function getEntryType(string memory key) public view returns (string memory) {
        if (!_exists[key]) {
            revert ContractNotFound(key);
        }
        return _entryType[key];
    }

    /**
     * @notice Start a deployment session
     */
    function startDeployment(address deployer, string memory network, string memory version) public {
        _metadata.deployer = deployer;
        _metadata.startedAt = block.timestamp;
        _metadata.startBlock = block.number;
        _metadata.network = network;
        _metadata.version = version;
    }

    /**
     * @notice Finish a deployment session
     */
    function finishDeployment() public {
        _metadata.finishedAt = block.timestamp;
    }

    /**
     * @notice Get deployment metadata
     */
    function getMetadata() public view returns (DeploymentMetadata memory) {
        return _metadata;
    }

    // ============================================================================
    // Internal Helpers
    // ============================================================================

    /**
     * @notice Internal function to register a contract
     */
    function _registerContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        string memory category
    ) internal {
        _contracts[key] = ContractEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: contractType,
                contractPath: contractPath,
                txHash: bytes32(0),
                blockNumber: block.number,
                category: category
            })
        });

        _exists[key] = true;
        _entryType[key] = "contract";
        _keys.push(key);
    }

    /**
     * @notice Internal function to register a proxy
     */
    function _registerProxy(
        string memory key,
        address addr,
        string memory implementationKey,
        bytes32 salt,
        string memory saltString
    ) internal {
        _proxies[key] = ProxyEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: "ERC1967Proxy",
                contractPath: "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol",
                txHash: bytes32(0),
                blockNumber: block.number,
                category: "UUPS proxy"
            }),
            create3: Create3Info({salt: salt, saltString: saltString}),
            proxy: ProxyInfo({implementationKey: implementationKey})
        });

        _exists[key] = true;
        _entryType[key] = "proxy";
        _keys.push(key);
    }

    /**
     * @notice Internal function to register an implementation
     */
    function _registerImplementation(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal {
        _implementations[key] = ImplementationEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: contractType,
                contractPath: contractPath,
                txHash: bytes32(0),
                blockNumber: block.number,
                category: "contract"
            }),
            proxies: new string[](0) // Initialize empty dynamic array
        });

        _exists[key] = true;
        _entryType[key] = "implementation";
        _keys.push(key);
    }

    /**
     * @notice Internal function to register a library
     */
    function _registerLibrary(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal {
        _libraries[key] = LibraryEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: contractType,
                contractPath: contractPath,
                txHash: bytes32(0),
                blockNumber: block.number,
                category: "library"
            })
        });

        _exists[key] = true;
        _entryType[key] = "library";
        _keys.push(key);
    }

    /**
     * @notice Internal helper to set a string parameter
     */
    function _setStringParam(string memory key, string memory value) internal {
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _stringParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "string";
        _keys.push(key);

        emit ParameterSet(key, "string");
    }

    /**
     * @notice Internal helper to set a uint256 parameter
     */
    function _setUintParam(string memory key, uint256 value) internal {
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _uintParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "uint256";
        _keys.push(key);

        emit ParameterSet(key, "uint256");
    }

    /**
     * @notice Internal helper to set an int256 parameter
     */
    function _setIntParam(string memory key, int256 value) internal {
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _intParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "int256";
        _keys.push(key);

        emit ParameterSet(key, "int256");
    }

    /**
     * @notice Internal helper to set a bool parameter
     */
    function _setBoolParam(string memory key, bool value) internal {
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _boolParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "bool";
        _keys.push(key);

        emit ParameterSet(key, "bool");
    }

    /**
     * @notice Internal helper for string comparison
     */
    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
