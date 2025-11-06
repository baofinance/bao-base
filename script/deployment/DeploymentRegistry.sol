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
    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant DEPLOYMENT_SCHEMA_VERSION = 1;

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
        string saltString; // Human-readable salt (now matches the registry key)
        string proxyType; // Type of proxy: "UUPS", "Transparent", "Beacon", etc.
    }

    /// @notice Proxy-specific info (implementation reference)
    struct ProxyInfo {
        string implementationKey;
    }

    // ============================================================================
    // Entry Types (compose from embedded structs)
    // ============================================================================

    /// @notice Top-level deployment metadata
    struct DeploymentMetadata {
        address deployer;
        address owner;
        uint256 startTimestamp;
        uint256 finishTimestamp;
        uint256 startBlock;
        uint256 finishBlock;
        string network;
        string version;
        string systemSaltString;
    }

    /// @notice Lightweight run record for audit trail
    struct RunRecord {
        address deployer;
        uint256 startTimestamp;
        uint256 finishTimestamp;
        uint256 startBlock;
        uint256 finishBlock;
        bool finished;
    }

    /// @notice Contract entry (direct deployment, mock, existing)
    struct ContractEntry {
        DeploymentInfo info;
        address factory; // CREATE3 factory address (if CREATE3-deployed)
        address deployer; // Address that executed the deployment
    }

    /// @notice Proxy entry (always uses CREATE3)
    struct ProxyEntry {
        DeploymentInfo info;
        Create3Info create3;
        ProxyInfo proxy;
        address factory; // CREATE3 factory address
        address deployer; // Address that executed the deployment
    }

    /// @notice Library entry (always uses CREATE)
    struct LibraryEntry {
        DeploymentInfo info;
        address deployer; // Address that executed the deployment
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
    error AlreadyInitialized();
    error KeyRequired();

    // ============================================================================
    // Storage
    // ============================================================================

    DeploymentMetadata internal _metadata;
    RunRecord[] internal _runs;

    mapping(string => ContractEntry) internal _contracts;
    mapping(string => ProxyEntry) internal _proxies;
    mapping(string => LibraryEntry) internal _libraries;

    // Direct mappings for each parameter type (no struct wrappers)
    mapping(string => string) internal _stringParams;
    mapping(string => uint256) internal _uintParams;
    mapping(string => int256) internal _intParams;
    mapping(string => bool) internal _boolParams;

    mapping(string => bool) internal _exists;
    mapping(string => string) internal _entryType;
    string[] internal _keys;
    uint256 internal _schemaVersion;
    mapping(string => bool) internal _resumedProxies;

    function _fileext() internal pure virtual returns (string memory);

    function _filepath() internal view returns (string memory) {
        return _filepath(_metadata.network, _metadata.systemSaltString);
    }

    function _filepath(string memory network, string memory systemSaltString) internal view returns (string memory) {
        string memory dir = string.concat(_getBaseDirPrefix(), "deployments");
        if (_useNetworkSubdir()) {
            dir = string.concat(dir, "/", network);
        }
        return string.concat(dir, "/", systemSaltString, ".", _fileext());
    }

    function _loadRegistry(string memory filePath) internal virtual;
    function _saveRegistry() internal virtual;

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
    function get(string memory key) public view virtual returns (address) {
        if (!_exists[key]) {
            revert ContractNotFound(key);
        }

        string memory entryType = _entryType[key];

        if (_eq(entryType, "contract")) return _contracts[key].info.addr;
        if (_eq(entryType, "proxy")) return _proxies[key].info.addr;
        if (_eq(entryType, "implementation")) return _contracts[key].info.addr;
        if (_eq(entryType, "library")) return _libraries[key].info.addr;

        revert UnknownEntryType(entryType, key);
    }

    /**
     * @notice Check if contract is registered
     * @dev Internal - external callers should use HarborDeployment's type-safe has(Contract)
     */
    function has(string memory key) public view returns (bool) {
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
    function getString(string memory key) public view returns (string memory) {
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
    function getUint(string memory key) public view returns (uint256) {
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
    function getInt(string memory key) public view returns (int256) {
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
    function getBool(string memory key) public view returns (bool) {
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
    function setString(string memory key, string memory value) public virtual {
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _stringParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "string";
        _keys.push(key);

        emit ParameterSet(key, "string");
        _saveRegistry();
    }

    /**
     * @notice Set uint256 parameter
     * @param key Parameter identifier
     * @param value The uint256 value
     */
    function setUint(string memory key, uint256 value) public virtual {
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _uintParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "uint256";
        _keys.push(key);

        emit ParameterSet(key, "uint256");
        _saveRegistry();
    }

    /**
     * @notice Set int256 parameter
     * @param key Parameter identifier
     * @param value The int256 value
     */
    function setInt(string memory key, int256 value) public virtual {
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _intParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "int256";
        _keys.push(key);

        emit ParameterSet(key, "int256");
        _saveRegistry();
    }

    /**
     * @notice Set bool parameter
     * @param key Parameter identifier
     * @param value The bool value
     */
    function setBool(string memory key, bool value) public virtual {
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_exists[key]) {
            revert ParameterAlreadyExists(key);
        }

        _boolParams[key] = value;

        _exists[key] = true;
        _entryType[key] = "bool";
        _keys.push(key);

        emit ParameterSet(key, "bool");
        _saveRegistry();
    }

    /**
     * @notice Get all registered keys
     */
    function keys() external view returns (string[] memory) {
        return _keys;
    }

    /**
     * @notice Get entry type for a key
     */
    function getType(string memory key) external view returns (string memory) {
        if (!_exists[key]) {
            revert ContractNotFound(key);
        }
        return _entryType[key];
    }

    /**
     * @notice Get deployment metadata
     */
    function getMetadata() external view returns (DeploymentMetadata memory) {
        return _metadata;
    }

    /**
     * @notice Require that a run is active
     */
    function _requireActiveRun() internal view {
        require(_runs.length > 0, "No active run");
    }

    /**
     * @notice Initialize deployment metadata
     * @param owner The final owner address for all deployed contracts
     */
    function _initializeMetadata(
        address owner,
        string memory network,
        string memory version,
        string memory systemSaltString
    ) internal {
        if (_metadata.startTimestamp != 0) {
            revert AlreadyInitialized();
        }
        require(_runs.length == 0, "Cannot start: runs already exist");
        _schemaVersion = DEPLOYMENT_SCHEMA_VERSION;
        _metadata.deployer = address(this);
        _metadata.owner = owner;
        _metadata.startTimestamp = block.timestamp;
        _metadata.startBlock = block.number;
        _metadata.network = network;
        _metadata.version = version;
        _metadata.systemSaltString = systemSaltString;
        _metadata.finishTimestamp = 0;
        _metadata.finishBlock = 0;

        // Create initial run record
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
        _saveRegistry();
    }

    /**
     * @notice Update finishTimestamp timestamp and block to current time/block
     * @dev Called on every save to track last modification time
     */
    function _updateFinishedAt() internal {
        _metadata.finishTimestamp = block.timestamp;
        _metadata.finishBlock = block.number;

        // Update current run's finish fields (but don't mark as finished)
        require(_runs.length > 0, "No active run");
        _runs[_runs.length - 1].finishTimestamp = block.timestamp;
        _runs[_runs.length - 1].finishBlock = block.number;
    }

    // ============================================================================
    // Internal Helpers
    // ============================================================================

    /**
     * @notice Internal function to register a standard contract (implementations, libraries, mocks, existing)
     */
    function _registerStandardContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        string memory category,
        address factory,
        address deployer
    ) internal virtual {
        _requireActiveRun();
        _requireValidAddress(key, addr);
        _contracts[key] = ContractEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: contractType,
                contractPath: contractPath,
                txHash: bytes32(0),
                blockNumber: block.number,
                category: category
            }),
            factory: factory,
            deployer: deployer
        });

        _exists[key] = true;
        _entryType[key] = "contract";
        _keys.push(key);
        _saveRegistry();
    }

    /**
     * @notice Internal function to register a proxy
     */
    function _registerProxy(
        string memory key,
        address addr,
        string memory implementationKey,
        bytes32 salt,
        string memory saltString,
        string memory proxyType,
        address factory,
        address deployer
    ) internal {
        _requireActiveRun();
        _proxies[key] = ProxyEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: "ERC1967Proxy",
                contractPath: "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol",
                txHash: bytes32(0),
                blockNumber: block.number,
                category: string.concat(proxyType, " proxy")
            }),
            create3: Create3Info({salt: salt, saltString: saltString, proxyType: proxyType}),
            proxy: ProxyInfo({implementationKey: implementationKey}),
            factory: factory,
            deployer: deployer
        });

        _exists[key] = true;
        _entryType[key] = "proxy";
        _keys.push(key);
        _resumedProxies[key] = false;
        _saveRegistry();
    }

    function _getProxy(string memory key) internal view returns (address proxy) {
        proxy = _proxies[key].info.addr;
        if (proxy == address(0)) {
            revert ContractNotFound(key);
        }
    }

    /**
     * @notice Update proxy's implementation reference after upgrade
     * @param proxyKey The key of the proxy being upgraded
     * @param newImplementationKey The key of the new implementation
     */
    function _updateProxyImplementation(string memory proxyKey, string memory newImplementationKey) internal virtual {
        _requireActiveRun();
        _proxies[proxyKey].proxy.implementationKey = newImplementationKey;
        _saveRegistry();
    }

    /**
     * @notice Internal function to register an implementation (stored as contract)
     */
    function _registerImplementation(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) internal {
        _requireActiveRun();
        _contracts[key] = ContractEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: contractType,
                contractPath: contractPath,
                txHash: bytes32(0),
                blockNumber: block.number,
                category: "contract"
            }),
            factory: address(0), // Implementations use regular CREATE, not CREATE3
            deployer: deployer
        });

        _exists[key] = true;
        _entryType[key] = "implementation";
        _keys.push(key);
        _saveRegistry();
    }

    function _getImplementation(string memory key) internal view returns (address implementation) {
        implementation = _contracts[key].info.addr;
        if (implementation == address(0)) {
            revert ContractNotFound(key);
        }
    }

    /**
     * @notice Internal function to register a library
     */
    function _registerLibrary(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) internal {
        _requireActiveRun();
        _requireValidLibrary(key, addr);
        _libraries[key] = LibraryEntry({
            info: DeploymentInfo({
                addr: addr,
                contractType: contractType,
                contractPath: contractPath,
                txHash: bytes32(0),
                blockNumber: block.number,
                category: "library"
            }),
            deployer: deployer
        });

        _exists[key] = true;
        _entryType[key] = "library";
        _keys.push(key);
        _saveRegistry();
    }

    function _requireValidAddress(string memory key, address addr) internal view {
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (addr == address(0)) {
            revert InvalidAddress(key);
        }
        if (_exists[key]) {
            revert ContractAlreadyExists(key);
        }
    }

    function _requireValidLibrary(string memory key, address addr) internal view {
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (addr == address(0)) {
            revert InvalidAddress(key);
        }
        if (_exists[key]) {
            revert LibraryAlreadyExists(key);
        }
    }

    /**
     * @notice Internal helper for string comparison
     */
    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
