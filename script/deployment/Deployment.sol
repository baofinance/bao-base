// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";

interface IUUPSUpgradeableProxy {
    function implementation() external view returns (address);
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

/**
 * @title Deployment
 * @notice Deployment operations with integrated data storage
 * @dev Responsibilities:
 *      - Deterministic proxy deployment via CREATE3
 *      - Library deployment via CREATE
 *      - Existing contract registration helpers
 *      - In-memory data storage (inherited from DeploymentDataMemory)
 *      - Designed for specialization (e.g. Harbor overrides deployProxy)
 */

abstract contract Deployment is DeploymentDataMemory {
    // ============================================================================
    // Errors
    // ============================================================================

    error ImplementationKeyRequired();
    error LibraryDeploymentFailed(string key);
    error OwnershipTransferFailed(address proxy);
    error FactoryDeploymentFailed(string reason);
    error ValueMismatch(uint256 expected, uint256 received);
    error KeyRequired();
    error SessionNotStarted();
    error SessionAlreadyFinished();
    error AlreadyInitialized();
    error CannotSendValueToNonPayableFunction();

    // ============================================================================
    // Types
    // ============================================================================

    /// @notice Proxy needing ownership transfer
    /// @dev Used by _getTransferrableProxies() and finish()
    struct TransferrableProxy {
        address proxy;
        string parentKey;
        address currentOwner;
        address configuredOwner;
    }

    // ============================================================================
    // Storage
    // ============================================================================

    // Note: Data storage (maps, getters, setters) inherited from DeploymentDataMemory

    /// @notice Bootstrap stub used as initial implementation for all proxies
    /// @dev Deployed once per session, owned by this harness, enables BaoOwnable compatibility with CREATE3
    UUPSProxyDeployStub internal _stub;

    /// @notice Session started flag
    enum State {
        NONE,
        STARTED,
        FINISHED
    }
    State internal _sessionState;

    /**
     * @notice Require that a run is active
     */
    function _requireActiveRun() internal view {
        if (_sessionState != State.STARTED) revert SessionNotStarted();
    }

    // ============================================================================
    // Factory Abstraction
    // ============================================================================

    /// @notice Get the deployer address for CREATE3 operations
    /// @dev Returns BaoDeployer address - same on all chains (deployed via Nick's Factory)
    ///      This is used for both prediction and deployment
    /// @return factory BaoDeployer contract address
    function _getCreate3Deployer() internal view virtual returns (address factory) {
        factory = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (factory == address(0)) {
            revert FactoryDeploymentFailed("BaoDeployer not configured");
        }
    }

    /// @notice Require that this deployment harness is configured as BaoDeployer operator
    /// @dev Production check - reverts if operator not already configured by multisig
    ///      Testing classes override this to auto-setup operator via VM.prank
    function _ensureBaoDeployerOperator() internal virtual;
    // TODO: this really ought to have a default implementation but this causes downstream diamonds
    //  {
    //     address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
    //     if (baoDeployer.code.length == 0) {
    //         revert FactoryDeploymentFailed("BaoDeployer missing code");
    //     }
    //     if (BaoDeployer(baoDeployer).operator() != address(this)) {
    //         revert FactoryDeploymentFailed("BaoDeployer operator not configured for this deployer");
    //     }
    // }

    // ============================================================================
    // Deployment Lifecycle
    // ============================================================================

    /// @notice Start deployment session
    /// @dev Subclasses can override for custom initialization (e.g., JSON loading)
    /// @param network Network name (e.g., "mainnet", "arbitrum", "anvil")
    /// @param systemSaltString System salt string for deterministic addresses
    function start(string memory network, string memory systemSaltString, string memory startPoint) public virtual {
        if (_sessionState != State.NONE) revert AlreadyInitialized();

        _startSession(network, systemSaltString, startPoint);
    }

    /// @notice Internal session initialization - called by start() and subclasses
    /// @dev Sets up session metadata and deployment infrastructure
    function _startSession(string memory network, string memory systemSaltString, string memory /*startPoint*/) internal {
        // TODO: need to read the schema version and check for compatibility
        // Set global deployment configuration
        _writeUint(SCHEMA_VERSION, 1, DataType.UINT);
        _writeString(SYSTEM_SALT_STRING, systemSaltString, DataType.STRING);

        // Initialize session metadata
        _writeString(SESSION_NETWORK, network, DataType.STRING);
        _writeAddress(SESSION_DEPLOYER, address(this), DataType.ADDRESS);
        _writeUint(SESSION_START_TIMESTAMP, block.timestamp, DataType.UINT);
        _writeString(SESSION_STARTED, _formatTimestamp(block.timestamp), DataType.STRING);
        _writeUint(SESSION_START_BLOCK, block.number, DataType.UINT);

        // Don't initialize finish fields - they only appear when finish() is called

        // Set up deployment infrastructure
        _ensureBaoDeployerOperator();
        _stub = new UUPSProxyDeployStub();

        _sessionState = State.STARTED;
    }

    /// @notice Finish deployment session
    /// @dev Transfers ownership to final owner for all proxies if current owner != configured owner
    /// @dev Uses runtime owner() check - only transfers if currentOwner != finalOwner
    ///      Looks for keys ending in ".ownershipModel" with value "transfer-after-deploy"
    /// @return transferred Number of proxies whose ownership was transferred
    function finish() public virtual returns (uint256 transferred) {
        if (_sessionState == State.NONE) revert SessionNotStarted();
        if (_sessionState == State.FINISHED) revert SessionAlreadyFinished();

        TransferrableProxy[] memory proxies = _getTransferrableProxies();
        transferred = proxies.length;

        for (uint256 i; i < proxies.length; i++) {
            TransferrableProxy memory tp = proxies[i];
            IBaoOwnable(tp.proxy).transferOwnership(tp.configuredOwner);
            _setString(string.concat(tp.parentKey, ".implementation.ownershipModel"), "transferred-after-deploy");
        }

        // Mark session finished
        _writeUint(SESSION_FINISH_TIMESTAMP, block.timestamp, DataType.UINT);
        _writeString(SESSION_FINISHED, _formatTimestamp(block.timestamp), DataType.STRING);
        _writeUint(SESSION_FINISH_BLOCK, block.number, DataType.UINT);
        _sessionState = State.FINISHED;

        return transferred;
    }

    /// @notice Get list of proxies needing ownership transfer
    /// @dev Finds all keys ending in ".implementation.ownershipModel" with value "transfer-after-deploy"
    ///      Performs runtime ownership check - only returns proxies where currentOwner != configuredOwner
    /// @return proxies Array of TransferrableProxy structs (only those actually needing transfer)
    function _getTransferrableProxies() internal view returns (TransferrableProxy[] memory proxies) {
        address globalOwner = _getAddress(OWNER);
        string[] memory allKeys = this.keys();
        string memory suffix = ".implementation.ownershipModel";
        uint256 suffixLen = bytes(suffix).length;

        // Allocate max-size array, populate, then truncate via assembly
        proxies = new TransferrableProxy[](allKeys.length);
        uint256 count = 0;

        for (uint256 i; i < allKeys.length; i++) {
            string memory key = allKeys[i];
            if (!LibString.endsWith(key, suffix)) continue;
            if (!LibString.eq(_getString(key), "transfer-after-deploy")) continue;

            // parentKey is the proxy key (strip ".implementation.ownershipModel")
            string memory parentKey = LibString.slice(key, 0, bytes(key).length - suffixLen);
            address proxy = _get(parentKey);

            (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
            if (!success || data.length != 32) continue;

            address currentOwner = abi.decode(data, (address));
            string memory ownerKey = string.concat(parentKey, ".owner");
            address configuredOwner = _has(ownerKey) ? _getAddress(ownerKey) : globalOwner;

            if (currentOwner != configuredOwner) {
                proxies[count++] = TransferrableProxy(proxy, parentKey, currentOwner, configuredOwner);
            }
        }

        // Truncate array to actual size
        assembly {
            mstore(proxies, count)
        }
    }

    // function dataStore() public view returns (address) {
    //     return address(_data);
    // }

    /// @notice Transfer ownership of a proxy to final owner
    /// @dev Called by subclass during finish() for each proxy
    /// @param proxy Proxy address
    function _transferProxyOwnership(address proxy) internal {
        // Check if proxy supports owner() method (BaoOwnable pattern)
        (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
        if (!success || data.length != 32) {
            // Contract doesn't support BaoOwnable, skip
            return;
        }

        address currentOwner = abi.decode(data, (address));
        address finalOwner = _readAddress(OWNER);

        // Only transfer if current owner is this harness (temporary owner from stub pattern)
        if (currentOwner == address(this)) {
            IBaoOwnable(proxy).transferOwnership(finalOwner);
        }
    }

    /// @notice Deploy BaoDeployer if needed (primarily for tests)
    /// @dev Production deployments should assume BaoDeployer already exists
    ///      This is here for test convenience only
    function ensureBaoDeployer() public {
        address deployed = DeploymentInfrastructure.ensureBaoDeployer();
        if (_sessionState == State.STARTED) {
            useExisting("BaoDeployer", deployed);
        }
    }

    // ============================================================================
    // Proxy Deployment / Upgrades
    // ============================================================================

    /// @notice Predict proxy address without deploying
    /// @param proxyKey Key for the proxy deployment
    /// @return proxy Predicted proxy address
    function predictProxyAddress(string memory proxyKey) public view returns (address proxy) {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        string memory systemSalt = _deriveSystemSalt();
        bytes memory proxySaltBytes = abi.encodePacked(systemSalt, "/", proxyKey, "/UUPS/proxy");
        bytes32 salt = EfficientHashLib.hash(proxySaltBytes);
        address deployer = _getCreate3Deployer();
        proxy = CREATE3.predictDeterministicAddress(salt, deployer);
    }

    /// @notice Deploy a UUPS proxy using bootstrap stub pattern (with value)
    function deployProxy(
        uint256 value,
        string memory proxyKey,
        address implementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        string memory implementationContractPath,
        address deployer
    ) public payable {
        _requireActiveRun();
        if (msg.value != value) {
            revert ValueMismatch(value, msg.value);
        }
        _deployProxy(
            value,
            proxyKey,
            implementation,
            implementationInitData,
            implementationContractType,
            implementationContractPath,
            deployer
        );
        _setUint(string.concat(proxyKey, ".value"), value);
    }

    /// @notice Deploy a UUPS proxy using bootstrap stub pattern
    /// @dev Three-step process:
    ///      1. Deploy ERC1967Proxy via CREATE3 pointing to stub (no initialization)
    ///      2. Call proxy.upgradeToAndCall(implementation, initData) to atomically upgrade and initialize
    ///      During initialization, msg.sender = this harness (via stub ownership), enabling BaoOwnable compatibility
    /// @param proxyKey Key for the proxy deployment
    /// @param implementation address of the implementation to use
    /// @param implementationInitData Initialization data to pass to implementation (includes owner if needed)
    function deployProxy(
        string memory proxyKey,
        address implementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        string memory implementationContractPath,
        address deployer
    ) public {
        _deployProxy(
            0,
            proxyKey,
            implementation,
            implementationInitData,
            implementationContractType,
            implementationContractPath,
            deployer
        );
    }

    function _deployProxy(
        uint256 value,
        string memory proxyKey,
        address implementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        string memory implementationContractPath,
        address deployer
    ) internal {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        require(implementation != address(0), "Implementation address is zero");

        // Compute salt for CREATE3 using system salt from data layer
        string memory systemSalt = _deriveSystemSalt();
        bytes memory proxySaltBytes = abi.encodePacked(systemSalt, "/", proxyKey, "/UUPS/proxy");
        bytes32 salt = EfficientHashLib.hash(proxySaltBytes);

        address factory = DeploymentInfrastructure.predictBaoDeployerAddress();

        bytes memory proxyCreationCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(_stub), bytes(""))
        );

        BaoDeployer baoDeployer = BaoDeployer(factory);

        bytes32 commitment = DeploymentInfrastructure.commitment(
            address(this),
            0,
            salt,
            EfficientHashLib.hash(proxyCreationCode)
        );
        baoDeployer.commit(commitment);
        address proxy = baoDeployer.reveal(proxyCreationCode, salt, 0);

        // Register proxy with all metadata (extracted to avoid stack too deep)
        _registerProxy(proxyKey, proxy, factory, salt, deployer);

        _upgradeProxy(
            value,
            proxyKey,
            implementation,
            implementationInitData,
            implementationContractType,
            implementationContractPath,
            deployer
        );
    }

    /// @notice Register proxy metadata
    /// @dev Extracted to separate function to avoid stack too deep errors
    ///      Note: ownershipModel is set via registerImplementation, not here
    function _registerProxy(
        string memory proxyKey,
        address proxy,
        address factory,
        bytes32 salt,
        address deployer
    ) private {
        // register keys
        // the proxy
        _recordContractFields(
            proxyKey,
            proxy,
            "ERC1967Proxy",
            "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol",
            deployer
        );
        // extra proxy keys
        _setAddress(string.concat(proxyKey, ".factory"), factory);
        _setString(string.concat(proxyKey, ".category"), "UUPS proxy");
        _setString(string.concat(proxyKey, ".saltString"), _extractSaltString(proxyKey));
        _setString(string.concat(proxyKey, ".salt"), LibString.toHexString(uint256(salt)));
    }

    /** @notice Upgrade existing proxy to new implementation
     */

    function upgradeProxy(
        string memory proxyKey,
        address newImplementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        string memory implementationContractPath,
        address deployer
    ) public {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        _upgradeProxy(
            0,
            proxyKey,
            newImplementation,
            implementationInitData,
            implementationContractType,
            implementationContractPath,
            deployer
        );
    }

    function upgradeProxy(
        uint256 value,
        string memory proxyKey,
        address newImplementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        string memory implementationContractPath,
        address deployer
    ) public payable {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        _upgradeProxy(
            value,
            proxyKey,
            newImplementation,
            implementationInitData,
            implementationContractType,
            implementationContractPath,
            deployer
        );
        _setUint(string.concat(proxyKey, ".value"), value);
    }

    function _upgradeProxy(
        uint256 value,
        string memory proxyKey,
        address newImplementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        string memory implementationContractPath,
        address deployer
    ) private {
        address proxy = _get(proxyKey);

        require(proxy != address(0), "Proxy address is zero");
        require(newImplementation != address(0), "Implementation address is zero");

        // Perform the upgrade
        if ((implementationInitData.length == 0) && (value == 0)) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
        } else if ((implementationInitData.length == 0) && (value != 0)) {
            revert CannotSendValueToNonPayableFunction();
            // or upgrade and call
        } else if ((implementationInitData.length != 0) && (value == 0)) {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(newImplementation, implementationInitData);
        } else if ((implementationInitData.length != 0) && (value != 0)) {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall{value: value}(newImplementation, implementationInitData);
        }

        // implementation keys
        string memory implKey = string.concat(proxyKey, ".implementation");
        _recordContractFields(
            implKey,
            newImplementation,
            implementationContractType,
            implementationContractPath,
            deployer
        );
        // Set default ownershipModel if not already set by registerImplementation
        string memory ownershipModelKey = string.concat(implKey, ".ownershipModel");
        if (!_has(ownershipModelKey)) {
            _setString(ownershipModelKey, "transfer-after-deploy");
        }
    }

    function predictableDeployContract(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) public payable {
        if (msg.value != value) {
            revert ValueMismatch(value, msg.value);
        }
        _predictableDeployContract(value, key, initCode, contractType, contractPath, deployer);
        _setUint(string.concat(key, ".value"), value);
    }

    function predictableDeployContract(
        string memory key,
        bytes memory initCode,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) public {
        return _predictableDeployContract(0, key, initCode, contractType, contractPath, deployer);
    }

    function _predictableDeployContract(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) internal {
        _requireActiveRun();
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }

        // Compute salt
        bytes32 salt = EfficientHashLib.hash(abi.encodePacked(_getString(SYSTEM_SALT_STRING), "/", key, "/contract"));

        // commit-reveal via to avoid front-running the deployment which could steal our address
        address factory = DeploymentInfrastructure.predictBaoDeployerAddress();
        BaoDeployer baoDeployer = BaoDeployer(factory);
        baoDeployer.commit(DeploymentInfrastructure.commitment(address(this), value, salt, keccak256(initCode)));
        address addr = baoDeployer.reveal{value: value}(initCode, salt, value);

        _recordContractFields(key, addr, contractType, contractPath, deployer);
        _setString(string.concat(key, ".category"), "contract");
        _setAddress(string.concat(key, ".factory"), factory);
        if (value > 0) {
            _setUint(string.concat(key, ".value"), value);
        }
    }

    /// @notice Register existing contract address
    function useExisting(string memory key, address addr) public virtual {
        _requireActiveRun();
        _set(key, addr);
        _setString(string.concat(key, ".category"), "existing");
    }

    /// @notice Register a standalone contract (non-proxy)
    function registerContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) public {
        _requireActiveRun();
        _recordContractFields(key, addr, contractType, contractPath, deployer);
        _setString(string.concat(key, ".category"), "contract");
    }

    /// @notice Register implementation for a proxy before calling deployProxy
    /// @dev Must be called before deployProxy. Sets the implementation address and ownership model.
    /// @param proxyKey The proxy key (e.g., "contracts.Oracle")
    /// @param implAddress The implementation contract address
    /// @param contractType The implementation contract type (e.g., "OracleV1")
    /// @param contractPath The source file path
    /// @param ownershipModel The ownership transfer model:
    ///        - "transfer-after-deploy": finish() will call transferOwnership (BaoOwnable)
    ///        - "transferred-on-timeout": ownership transfers automatically after timeout (BaoOwnable_v2)
    function registerImplementation(
        string memory proxyKey,
        address implAddress,
        string memory contractType,
        string memory contractPath,
        string memory ownershipModel
    ) public {
        _requireActiveRun();
        string memory implKey = string.concat(proxyKey, ".implementation");
        _recordContractFields(implKey, implAddress, contractType, contractPath, address(this));
        _setString(string.concat(implKey, ".ownershipModel"), ownershipModel);
    }

    /// @dev Record common contract metadata fields
    function _recordContractFields(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) private {
        _set(key, addr);
        _setString(string.concat(key, ".contractType"), contractType);
        _setString(string.concat(key, ".contractPath"), contractPath);
        _setAddress(string.concat(key, ".deployer"), deployer);
        _setUint(string.concat(key, ".blockNumber"), block.number);
    }

    /// @notice Deploy library using CREATE
    function deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) public {
        _requireActiveRun();

        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        if (addr == address(0)) {
            revert LibraryDeploymentFailed(key);
        }

        _set(key, addr);
        _setString(string.concat(key, ".category"), "library");
        _setString(string.concat(key, ".contractType"), contractType);
        _setString(string.concat(key, ".contractPath"), contractPath);
        _setAddress(string.concat(key, ".deployer"), deployer);
        _setUint(string.concat(key, ".blockNumber"), block.number);
    }

    function _afterValueChanged(string memory key) internal virtual;

    // Note: keys() and schemaKeys() are inherited from DeploymentDataMemory/DeploymentKeys

    /// @notice Set contract address (key.address)
    function _set(string memory key, address value) internal {
        _writeAddress(string.concat(key, ".address"), value, DataType.ADDRESS);
        _afterValueChanged(key);
    }

    /// @notice Get contract address (shorthand for key.address)
    function _get(string memory key) internal view returns (address) {
        // get(key) returns the address at key.address
        return _readAddress(string.concat(key, ".address"));
    }

    /// @notice Extract salt string from key (everything after last dot)
    function _extractSaltString(string memory key) internal pure returns (string memory) {
        bytes memory keyBytes = bytes(key);
        uint256 lastDotIndex = 0;

        // Find the last dot
        for (uint256 i = 0; i < keyBytes.length; i++) {
            if (keyBytes[i] == ".") {
                lastDotIndex = i;
            }
        }

        // If no dot found, return the whole key
        if (lastDotIndex == 0) {
            return key;
        }

        // Extract substring after last dot
        bytes memory result = new bytes(keyBytes.length - lastDotIndex - 1);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = keyBytes[lastDotIndex + 1 + i];
        }

        return string(result);
    }

    /// @notice Check if contract key exists
    /// @dev Uses external has() which handles OBJECT type checks (key.address)
    function _has(string memory key) internal view returns (bool) {
        return this.has(key);
    }

    /// @notice Set string value
    function _setString(string memory key, string memory value) internal {
        _writeString(key, value, DataType.STRING);
        _afterValueChanged(key);
    }

    /// @notice Get string value
    function _getString(string memory key) internal view returns (string memory) {
        return _readString(key);
    }

    /// @notice Set uint value
    function _setUint(string memory key, uint256 value) internal {
        _writeUint(key, value, DataType.UINT);
        _afterValueChanged(key);
    }

    /// @notice Get uint value
    function _getUint(string memory key) internal view returns (uint256) {
        return _readUint(key);
    }

    /// @notice Set int value
    function _setInt(string memory key, int256 value) internal {
        _writeInt(key, value, DataType.INT);
        _afterValueChanged(key);
    }

    /// @notice Get int value
    function _getInt(string memory key) internal view returns (int256) {
        return _readInt(key);
    }

    /// @notice Set bool value
    function _setBool(string memory key, bool value) internal {
        _writeBool(key, value, DataType.BOOL);
        _afterValueChanged(key);
    }

    /// @notice Get bool value
    function _getBool(string memory key) internal view returns (bool) {
        return _readBool(key);
    }

    function _setAddress(string memory key, address value) internal {
        _writeAddress(key, value, DataType.ADDRESS);
        _afterValueChanged(key);
    }

    function _getAddress(string memory key) internal view returns (address) {
        return _readAddress(key);
    }

    /// @notice Set address array
    function _setAddressArray(string memory key, address[] memory values) internal {
        _writeAddressArray(key, values, DataType.ADDRESS_ARRAY);
        _afterValueChanged(key);
    }

    /// @notice Get address array
    function _getAddressArray(string memory key) internal view returns (address[] memory) {
        return _readAddressArray(key);
    }

    /// @notice Set string array
    function _setStringArray(string memory key, string[] memory values) internal {
        _writeStringArray(key, values, DataType.STRING_ARRAY);
        _afterValueChanged(key);
    }

    /// @notice Get string array
    function _getStringArray(string memory key) internal view returns (string[] memory) {
        return _readStringArray(key);
    }

    /// @notice Set uint array
    function _setUintArray(string memory key, uint256[] memory values) internal {
        _writeUintArray(key, values, DataType.UINT_ARRAY);
        _afterValueChanged(key);
    }

    /// @notice Get uint array
    function _getUintArray(string memory key) internal view returns (uint256[] memory) {
        return _readUintArray(key);
    }

    /// @notice Set int array
    function _setIntArray(string memory key, int256[] memory values) internal {
        _writeIntArray(key, values, DataType.INT_ARRAY);
        _afterValueChanged(key);
    }

    /// @notice Get int array
    function _getIntArray(string memory key) internal view returns (int256[] memory) {
        return _readIntArray(key);
    }

    /// @notice Derive system salt for deterministic address calculations
    /// @dev Subclasses can override to customize salt derivation (e.g., network-specific tweaks)
    function _deriveSystemSalt() internal view virtual returns (string memory) {
        return _readString(SYSTEM_SALT_STRING);
    }

    /// @notice Format Unix timestamp as ISO 8601 string
    /// @param timestamp Unix timestamp in seconds
    /// @return ISO 8601 formatted string (YYYY-MM-DDTHH:MM:SSZ)
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

    /// @notice Pad number with leading zeros
    /// @param num Number to pad
    /// @param width Target width
    /// @return Padded string
    function _padZero(uint256 num, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(LibString.toString(num));
        if (b.length >= width) return string(b);

        bytes memory padded = new bytes(width);
        uint256 paddingNeeded = width - b.length;

        for (uint256 i = 0; i < paddingNeeded; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[paddingNeeded + i] = b[i];
        }

        return string(padded);
    }
}
