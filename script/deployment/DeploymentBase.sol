// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {console2} from "forge-std/console2.sol";

import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";

interface IUUPSUpgradeableProxy {
    function implementation() external view returns (address);
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

/**
 * @title DeploymentBase
 * @notice Abstract base for deployment operations with integrated data storage
 * @dev Responsibilities:
 *      - Deterministic proxy deployment via CREATE3
 *      - Library deployment via CREATE
 *      - Existing contract registration helpers
 *      - In-memory data storage (inherited from DeploymentDataMemory)
 *      - Designed for specialization via mixins
 *
 *      This is the abstract base - it does NOT provide a default _ensureBaoFactory().
 *      Concrete classes must either:
 *      - Extend Deployment (which provides production default)
 *      - Mix in DeploymentTesting (for tests with current build bytecode)
 *      - Provide a custom `_ensureBaoFactory()` (e.g., DeploymentTesting for dev bytecode)
 */

abstract contract DeploymentBase is DeploymentDataMemory {
    using LibString for string;

    // ============================================================================
    // Errors
    // ============================================================================

    error ImplementationKeyRequired();
    error LibraryDeploymentFailed(string key);
    error OwnershipTransferFailed(address proxy);
    error MissingOwnerFunction(string proxyKey, address proxy);
    error FactoryDeploymentFailed(string reason);
    error FactoryOperatorNotConfigured(address deployer);
    error ValueMismatch(uint256 expected, uint256 received);
    error KeyRequired();
    error SessionNotStarted();
    error SessionAlreadyFinished();
    error RoleValueMismatch(string roleKey, uint256 existingValue, uint256 newValue);
    error DuplicateGrantee(string roleKey, string granteeKey);
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

    /// @notice Proxy with timeout-based ownership transfer
    /// @dev Used by _getTimeoutProxies() and finish()
    struct TimeoutProxy {
        string parentKey;
        address configuredOwner;
    }

    // ============================================================================
    // Storage
    // ============================================================================

    /// @notice Session started flag
    enum State {
        NONE,
        STARTED,
        FINISHED
    }
    State private _sessionState;

    /**
     * @notice Require that a run is active
     */
    function _requireActiveRun() internal view {
        if (_sessionState != State.STARTED) revert SessionNotStarted();
    }

    // ============================================================================
    // Broadcast Hooks
    // ============================================================================

    /// @notice Hook called before blockchain operations
    /// @dev Override in script classes to call vm.startBroadcast()
    function _deployer() internal virtual returns (address deployer);

    /// @notice Hook called before blockchain operations
    /// @dev Override in script classes to call vm.startBroadcast()
    function _startBroadcast() internal virtual returns (address deployer);

    /// @notice Hook called after blockchain operations
    /// @dev Override in script classes to call vm.stopBroadcast()
    ///      Default is no-op (works for tests where no broadcast is needed)
    function _stopBroadcast() internal virtual;

    // ============================================================================
    // Deployment Lifecycle
    // ============================================================================

    /// @notice Ensure BaoFactory is deployed and return its address
    /// @dev ABSTRACT - must be implemented by mixins:
    ///      - Deployment: production bytecode (default)
    ///      - DeploymentTesting: current build + operator setup
    ///      - Any contract that overrides `_ensureBaoFactory()` for alternative bytecode
    function _ensureBaoFactory() internal virtual returns (address factory);

    function _beforeStart(
        string memory /* network */,
        string memory /* systemSaltString */,
        string memory /* startPoint */
    ) internal virtual;

    /// @notice Start deployment session
    /// @dev Subclasses can override for custom initialization (e.g., JSON loading)
    /// @param network Network name (e.g., "mainnet", "arbitrum", "anvil")
    /// @param systemSaltString System salt string for deterministic addresses
    function start(string memory network, string memory systemSaltString, string memory startPoint) public virtual {
        if (_sessionState != State.NONE) revert AlreadyInitialized();

        _beforeStart(network, systemSaltString, startPoint);

        // TODO: need to read the schema version and check for compatibility
        // Set global deployment configuration
        _setUint(SCHEMA_VERSION, 1);
        _setString(SYSTEM_SALT_STRING, systemSaltString);

        // Initialize session metadata
        _setString(SESSION_NETWORK, network);
        _setUint(SESSION_CHAIN_ID, block.chainid);
        _setUint(SESSION_START_TIMESTAMP, block.timestamp);
        _setString(SESSION_STARTED, _formatTimestamp(block.timestamp));
        _setUint(SESSION_START_BLOCK, block.number);

        // start the evm interaction
        address deployer = _startBroadcast();
        _setAddress(SESSION_DEPLOYER, deployer);
        console2.log("deployer = %s", deployer);

        // Set up deployment infrastructure
        // in all scenarios we can deploy it
        address baoFactory = _ensureBaoFactory();
        console2.log("BaoFactory = %s", baoFactory);
        _setAddress(BAO_FACTORY, baoFactory);

        // Deploy stub (testing classes override, scripts use setStub before start)
        UUPSProxyDeployStub stub = new UUPSProxyDeployStub();
        console2.log("UUPSProxyDeployStub = %s", address(stub));
        console2.log("UUPSProxyDeployStub.owner() = %s", stub.owner());
        _set(SESSION_STUB, address(stub));
        _setString(SESSION_STUB_CONTRACT_TYPE, "UUPSProxyDeployStub");
        _setString(SESSION_STUB_CONTRACT_PATH, "script/deployment/UUPSProxyDeployStub.sol");
        _setUint(SESSION_STUB_BLOCK_NUMBER, block.number);

        _sessionState = State.STARTED;

        _save();
    }

    /// @notice Finish deployment session
    /// @dev Transfers ownership to final owner for all proxies if current owner != configured owner
    /// @dev Uses runtime owner() check - only transfers if currentOwner != finalOwner
    ///      Looks for keys ending in ".ownershipModel" with value "transfer-after-deploy"
    ///      Also updates metadata for "transferred-on-timeout" proxies (no transferOwnership call needed)
    /// @return transferred Number of proxies whose ownership was transferred
    function finish() public virtual returns (uint256 transferred) {
        if (_sessionState == State.NONE) revert SessionNotStarted();
        if (_sessionState == State.FINISHED) revert SessionAlreadyFinished();

        TransferrableProxy[] memory proxies = _getTransferrableProxies();
        transferred = proxies.length;

        // Transfer ownership (needs broadcast in script context)
        for (uint256 i; i < proxies.length; i++) {
            TransferrableProxy memory tp = proxies[i];
            IBaoOwnable(tp.proxy).transferOwnership(tp.configuredOwner);
        }

        // Update metadata after blockchain operations for transfer-after-deploy proxies
        for (uint256 i; i < proxies.length; i++) {
            TransferrableProxy memory tp = proxies[i];
            _setAddress(string.concat(tp.parentKey, ".owner"), tp.configuredOwner);
            _setString(string.concat(tp.parentKey, ".implementation.ownershipModel"), "transferred-after-deploy");
        }

        // Update metadata for timeout-based proxies (no transferOwnership call, but update owner field)
        TimeoutProxy[] memory timeoutProxies = _getTimeoutProxies();
        for (uint256 i; i < timeoutProxies.length; i++) {
            TimeoutProxy memory tp = timeoutProxies[i];
            _setAddress(string.concat(tp.parentKey, ".owner"), tp.configuredOwner);
        }

        // Mark session finished (use _set* to trigger _afterValueChanged for persistence)
        _setUint(SESSION_FINISH_TIMESTAMP, block.timestamp);
        _setString(SESSION_FINISHED, _formatTimestamp(block.timestamp));
        _setUint(SESSION_FINISH_BLOCK, block.number);
        _sessionState = State.FINISHED;

        _stopBroadcast();
        _save();
        return transferred;
    }

    /// @notice Get list of proxies needing ownership transfer
    /// @dev Finds all keys ending in ".implementation.ownershipModel" with value "transfer-after-deploy"
    ///      Performs runtime ownership check - only returns proxies where currentOwner != configuredOwner
    /// @return proxies Array of TransferrableProxy structs (only those actually needing transfer)
    function _getTransferrableProxies() internal view returns (TransferrableProxy[] memory proxies) {
        string[] memory allKeys = keys();
        string memory suffix = ".implementation.ownershipModel";

        // Allocate max-size array, populate, then truncate via assembly
        proxies = new TransferrableProxy[](allKeys.length);
        uint256 count = 0;

        for (uint256 i; i < allKeys.length; i++) {
            string memory key = allKeys[i];
            if (!LibString.endsWith(key, suffix)) continue;
            if (!LibString.eq(_getString(key), "transfer-after-deploy")) continue;

            // parentKey is the proxy key (strip ".implementation.ownershipModel")
            string memory parentKey = LibString.slice(key, 0, bytes(key).length - bytes(suffix).length);
            address proxy = _get(parentKey);

            (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
            // Contracts marked transfer-after-deploy MUST have owner() function
            if (!success || data.length != 32) {
                revert MissingOwnerFunction(parentKey, proxy);
            }

            address currentOwner = abi.decode(data, (address));
            // Always transfer to the global configured owner
            if (currentOwner != _getAddress(OWNER)) {
                proxies[count++] = TransferrableProxy(proxy, parentKey, currentOwner, _getAddress(OWNER));
            }
        }

        // Truncate array to actual size
        assembly {
            mstore(proxies, count)
        }
    }

    /// @notice Get list of proxies with timeout-based ownership transfer
    /// @dev Finds all keys ending in ".implementation.ownershipModel" with value "transferred-on-timeout"
    ///      These proxies don't need explicit transferOwnership call, but their metadata should be updated
    /// @return proxies Array of TimeoutProxy structs
    function _getTimeoutProxies() internal view returns (TimeoutProxy[] memory proxies) {
        string[] memory allKeys = keys();
        string memory suffix = ".implementation.ownershipModel";

        // Allocate max-size array, populate, then truncate via assembly
        proxies = new TimeoutProxy[](allKeys.length);
        uint256 count = 0;

        for (uint256 i; i < allKeys.length; i++) {
            string memory key = allKeys[i];
            if (!LibString.endsWith(key, suffix)) continue;
            if (!LibString.eq(_getString(key), "transferred-on-timeout")) continue;

            // parentKey is the proxy key (strip ".implementation.ownershipModel")
            string memory parentKey = LibString.slice(key, 0, bytes(key).length - bytes(suffix).length);
            proxies[count++] = TimeoutProxy(parentKey, _getAddress(OWNER));
        }

        // Truncate array to actual size
        assembly {
            mstore(proxies, count)
        }
    }

    // function dataStore() public view returns (address) {
    //     return address(_data);
    // }

    /// @notice Deploy BaoFactory if needed (primarily for tests)
    /// @dev Production deployments should assume BaoFactory already exists
    ///      This is here for test convenience only
    function ensureBaoFactory() public {
        address deployed = _ensureBaoFactory();
        if (_sessionState == State.STARTED) {
            useExisting("BaoFactory", deployed);
        }
    }

    /// @dev Look up the source file path for a contract type by matching creation bytecode
    /// @param contractType The contract name (e.g., "MockERC20")
    /// @param creationCode The creation bytecode from type(Contract).creationCode for disambiguation
    function _lookupContractPath(
        string memory contractType,
        bytes memory creationCode
    ) internal view virtual returns (string memory path);

    // ============================================================================
    // Proxy Deployment / Upgrades
    // ============================================================================

    function _contractSalt(
        string memory key,
        string memory contractSaltKey
    ) private view returns (string memory saltString, bytes32 salt) {
        return _contractSalt(key, contractSaltKey, "");
    }

    function _contractSalt(
        string memory key,
        string memory contractSaltKey,
        string memory contractVariant
    ) private view returns (string memory saltString, bytes32 salt) {
        _requireActiveRun();
        string memory fixedKey = key;
        if (fixedKey.startsWith("contracts.")) {
            fixedKey = fixedKey.slice(10);
        }
        if (bytes(fixedKey).length == 0) {
            revert KeyRequired();
        }

        saltString = _getString(contractSaltKey);
        if (bytes(contractVariant).length > 0) {
            saltString = string.concat(saltString, "::", contractVariant);
        }
        saltString = string.concat(saltString, "::", fixedKey);
        salt = EfficientHashLib.hash(abi.encodePacked(saltString));
    }

    /// @notice Predict proxy address without deploying
    /// @param proxyKey Key for the proxy deployment
    /// @return proxy Predicted proxy address
    function predictAddress(string memory proxyKey, string memory contractSaltKey) public view returns (address proxy) {
        (, bytes32 salt) = _contractSalt(proxyKey, contractSaltKey);
        proxy = CREATE3.predictDeterministicAddress(salt, _getAddress(BAO_FACTORY));
    }

    function predictAddress(
        string memory proxyKey,
        string memory contractSaltKey,
        string memory contractVariant
    ) public view returns (address proxy) {
        (, bytes32 salt) = _contractSalt(proxyKey, contractSaltKey, contractVariant);
        proxy = CREATE3.predictDeterministicAddress(salt, _getAddress(BAO_FACTORY));
    }

    /// @notice Deploy a UUPS proxy using bootstrap stub pattern (with value)
    function deployProxy(
        uint256 value,
        string memory proxyKey,
        string memory contractSaltKey,
        address implementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        bytes memory implementationCreationCode,
        address deployer
    ) public payable {
        _requireActiveRun();
        if (msg.value != value) {
            revert ValueMismatch(value, msg.value);
        }
        _deployProxy(
            value,
            proxyKey,
            contractSaltKey,
            implementation,
            implementationInitData,
            implementationContractType,
            implementationCreationCode,
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
    /// @param implementationCreationCode The creation bytecode from type(Implementation).creationCode
    function deployProxy(
        string memory proxyKey,
        string memory contractSaltKey,
        address implementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        bytes memory implementationCreationCode,
        address deployer
    ) public {
        _deployProxy(
            0,
            proxyKey,
            contractSaltKey,
            implementation,
            implementationInitData,
            implementationContractType,
            implementationCreationCode,
            deployer
        );
    }

    function _deployProxy(
        uint256 value,
        string memory proxyKey,
        string memory contractSaltKey,
        address implementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        bytes memory implementationCreationCode,
        address deployer
    ) internal {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        require(implementation != address(0), "Implementation address is zero");

        // Compute salt for CREATE3 using system salt from data layer
        (string memory saltString, bytes32 salt) = _contractSalt(proxyKey, contractSaltKey);

        bytes memory proxyCreationCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(_get(SESSION_STUB), bytes(""))
        );

        address factory = _getAddress(BAO_FACTORY);
        IBaoFactory baoFactory = IBaoFactory(factory);

        // Deploy proxy via CREATE3 (needs broadcast in script context)
        address proxy = baoFactory.deploy(proxyCreationCode, salt);
        require(
            proxy == predictAddress(proxyKey, contractSaltKey),
            string.concat("proxy, '", proxyKey, "' predicted vs deployed address mismatch")
        );

        // Register proxy with all metadata (extracted to avoid stack too deep)
        // the proxy - use ERC1967Proxy's creation code for path lookup
        _recordContractFields(
            proxyKey,
            proxy,
            type(ERC1967Proxy).name,
            type(ERC1967Proxy).creationCode,
            deployer,
            block.number
        );
        // extra proxy keys
        _setAddress(string.concat(proxyKey, ".factory"), factory);
        _setAddress(string.concat(proxyKey, ".owner"), deployer);
        _setString(string.concat(proxyKey, ".category"), "UUPS proxy");
        _setString(string.concat(proxyKey, ".saltString"), saltString);
        _setString(string.concat(proxyKey, ".salt"), LibString.toHexString(uint256(salt)));

        // Record stub implementation (use empty bytecode - stub is internal, path not important)
        _recordContractFields(
            string.concat(proxyKey, ".implementation"),
            _get(SESSION_STUB),
            _getString(SESSION_STUB_CONTRACT_TYPE),
            "",
            _getAddress(SESSION_DEPLOYER),
            _getUint(SESSION_STUB_BLOCK_NUMBER)
        );

        _upgradeProxy(
            value,
            proxyKey,
            implementation,
            implementationInitData,
            implementationContractType,
            implementationCreationCode,
            deployer
        );
    }

    /** @notice Upgrade existing proxy to new implementation
     */

    function upgradeProxy(
        string memory proxyKey,
        address newImplementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        bytes memory implementationCreationCode,
        address deployer
    ) public {
        _upgradeProxy(
            0,
            proxyKey,
            newImplementation,
            implementationInitData,
            implementationContractType,
            implementationCreationCode,
            deployer
        );
    }

    function upgradeProxy(
        uint256 value,
        string memory proxyKey,
        address newImplementation,
        bytes memory implementationInitData,
        string memory implementationContractType,
        bytes memory implementationCreationCode,
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
            implementationCreationCode,
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
        bytes memory implementationCreationCode,
        address deployer
    ) private {
        address proxy = _get(proxyKey);

        require(proxy != address(0), "Proxy address is zero");
        require(newImplementation != address(0), "Implementation address is zero");

        // Perform the upgrade (needs broadcast in script context)
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
            implementationCreationCode,
            deployer,
            block.number
        );
        // Set default ownershipModel if not already set
        string memory ownershipModelKey = string.concat(implKey, ".ownershipModel");
        // TODO: fix the ownership transfer models - we only have one right now so it's not a problem atm
        if (!_has(ownershipModelKey)) {
            _setString(ownershipModelKey, "transfer-after-deploy");
        }
    }

    function predictableDeployContract(
        uint256 value,
        string memory key,
        string memory contractSaltKey,
        bytes memory initCode,
        string memory contractType,
        bytes memory creationCode,
        address deployer
    ) public payable {
        if (msg.value != value) {
            revert ValueMismatch(value, msg.value);
        }
        _predictableDeployContract(value, key, contractSaltKey, initCode, contractType, creationCode, deployer);
        _setUint(string.concat(key, ".value"), value);
    }

    function predictableDeployContract(
        string memory key,
        string memory contractSaltKey,
        bytes memory initCode,
        string memory contractType,
        bytes memory creationCode,
        address deployer
    ) public {
        return _predictableDeployContract(0, key, contractSaltKey, initCode, contractType, creationCode, deployer);
    }

    function _predictableDeployContract(
        uint256 value,
        string memory key,
        string memory contractSaltKey,
        bytes memory initCode,
        string memory contractType,
        bytes memory creationCode,
        address deployer
    ) internal {
        _requireActiveRun();
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }

        // Compute salt from system salt + key
        (, bytes32 salt) = _contractSalt(key, contractSaltKey);

        address factory = _getAddress(BAO_FACTORY);
        IBaoFactory baoFactory = IBaoFactory(factory);
        address addr = baoFactory.deploy{value: value}(value, initCode, salt);

        _recordContractFields(key, addr, contractType, creationCode, deployer, block.number);
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
    /// @param key The deployment key (e.g., "contracts.token")
    /// @param addr The deployed contract address
    /// @param contractType The contract name (e.g., "MockERC20")
    /// @param creationCode The creation bytecode from type(Contract).creationCode for path disambiguation
    /// @param deployer The address that deployed the contract
    function registerContract(
        string memory key,
        address addr,
        string memory contractType,
        bytes memory creationCode,
        address deployer
    ) public {
        _requireActiveRun();
        _recordContractFields(key, addr, contractType, creationCode, deployer, block.number);
        _setString(string.concat(key, ".category"), "contract");
    }

    /// @dev Record common contract metadata fields
    /// @param creationCode The creation bytecode for path lookup disambiguation
    function _recordContractFields(
        string memory key,
        address addr,
        string memory contractType,
        bytes memory creationCode,
        address deployer,
        uint256 blockNumber
    ) internal {
        _set(key, addr);
        _setString(string.concat(key, ".contractType"), contractType);
        _setString(string.concat(key, ".contractPath"), _lookupContractPath(contractType, creationCode));
        _setAddress(string.concat(key, ".deployer"), deployer);
        _setUint(string.concat(key, ".blockNumber"), blockNumber);
    }

    /// @notice Deploy library using CREATE
    /// @param bytecode The library's creation bytecode (also used for path disambiguation)
    function deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        address deployer
    ) public {
        _requireActiveRun();

        // Deploy library (needs broadcast in script context)
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        if (addr == address(0)) {
            revert LibraryDeploymentFailed(key);
        }
        // Pass bytecode as creationCode for path lookup disambiguation
        _recordContractFields(key, addr, contractType, bytecode, deployer, block.number);
        _setString(string.concat(key, ".category"), "library");
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

    // ============================================================================
    // Deployment verification helpers
    // ============================================================================

    function _expect(string memory actual, string memory expected, string memory key) internal pure {
        if (LibString.eq(actual, expected)) {
            console2.log(string.concat(unicode"✓ ", key, " = %s"), actual);
        } else {
            console2.log(string.concat("*** ERROR *** ", key, " = ", actual, "; expected = ", expected));
        }
    }

    function _expect(string memory actual, string memory key) internal view {
        _expect(actual, _getString(key), key);
    }

    function _expect(address actual, string memory key) internal view {
        _expect(LibString.toHexStringChecksummed(actual), LibString.toHexStringChecksummed(_get(key)), key);
    }

    function _expect(uint256 actual, string memory key) internal view {
        _expect(LibString.toString(actual), LibString.toString(_getUint(key)), key);
    }

    function _expect(int256 actual, string memory key) internal view {
        _expect(LibString.toString(actual), LibString.toString(_getInt(key)), key);
    }

    function toString(bool value) internal pure returns (string memory) {
        return value ? "true" : "false";
    }

    function _expect(bool actual, string memory key) internal view {
        _expect(toString(actual), toString(_getBool(key)), key);
    }

    function _expectCode(address addr) internal view {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        if (size > 0) {
            console2.log(string.concat(unicode"✓ Code exists at %s", LibString.toHexStringChecksummed(addr)));
        } else {
            console2.log(string.concat("*** ERROR *** No code at %s", LibString.toHexStringChecksummed(addr)));
        }
    }

    function _expect(address[] memory actual, string memory key) internal view {
        address[] memory expected = _getAddressArray(key);
        if (actual.length != expected.length) {
            console2.log(
                string.concat("*** ERROR *** ", key, " length = %d; expected = %d"),
                actual.length,
                expected.length
            );
            return;
        }
        for (uint256 i = 0; i < actual.length; i++) {
            if (actual[i] != expected[i]) {
                console2.log(
                    string.concat("*** ERROR *** ", key, "[%d] = %s; expected = %s"),
                    i,
                    LibString.toHexStringChecksummed(actual[i]),
                    LibString.toHexStringChecksummed(expected[i])
                );
                return;
            }
        }
        console2.log(string.concat(unicode"✓ ", key, " matches (%d elements)"), actual.length);
    }

    function _expect(uint256[] memory actual, string memory key) internal view {
        uint256[] memory expected = _getUintArray(key);
        if (actual.length != expected.length) {
            console2.log(
                string.concat("*** ERROR *** ", key, " length = %d; expected = %d"),
                actual.length,
                expected.length
            );
            return;
        }
        for (uint256 i = 0; i < actual.length; i++) {
            if (actual[i] != expected[i]) {
                console2.log(
                    string.concat("*** ERROR *** ", key, "[%d] = %d; expected = %d"),
                    i,
                    actual[i],
                    expected[i]
                );
                return;
            }
        }
        console2.log(string.concat(unicode"✓ ", key, " matches (%d elements)"), actual.length);
    }

    function _expect(int256[] memory actual, string memory key) internal view {
        int256[] memory expected = _getIntArray(key);
        if (actual.length != expected.length) {
            console2.log(
                string.concat("*** ERROR *** ", key, " length = %d; expected = %d"),
                uint256(int256(actual.length)),
                uint256(int256(expected.length))
            );
            return;
        }
        for (uint256 i = 0; i < actual.length; i++) {
            if (actual[i] != expected[i]) {
                console2.log(string.concat("*** ERROR *** ", key, "[%d] mismatch"), i);
                return;
            }
        }
        console2.log(string.concat(unicode"✓ ", key, " matches (%d elements)"), actual.length);
    }

    /// @notice Verify on-chain roles match recorded role grants
    /// @dev Computes expected bitmap from recorded grants and compares with actual
    /// @param actualValue The actual roles bitmap from the contract (e.g., contract.rolesOf(grantee))
    /// @param contractKey The contract where roles are defined (e.g., "contracts.pegged")
    /// @param roleName The grantee whose roles are being verified (e.g., "contracts.minter")
    function _expectRoleValue(uint256 actualValue, string memory contractKey, string memory roleName) internal view {
        _expect(actualValue, string.concat(contractKey, ".roles.", roleName, ".value"));
    }

    /// @notice Verify grantee has exactly the specified roles on a contract
    /// @dev Performs two checks:
    ///      1. On-chain bitmap matches the expected roles (from role names)
    ///      2. Recorded grantees in memory match (granteeKey is in grantees list for each role)
    /// @param actualBitmap The actual roles bitmap from the contract (e.g., contract.rolesOf(grantee))
    /// @param contractKey The contract where roles are defined (e.g., "contracts.pegged")
    /// @param roleNames Array of role names the grantee should have (e.g., ["MINTER_ROLE", "BURNER_ROLE"])
    /// @param granteeKey The grantee whose roles are being verified (e.g., "contracts.minter")
    function _expectRolesOf(
        uint256 actualBitmap,
        string memory contractKey,
        string[] memory roleNames,
        string memory granteeKey
    ) internal view {
        // Compute expected bitmap from the provided role names
        uint256 expectedBitmap = 0;
        for (uint256 i = 0; i < roleNames.length; i++) {
            expectedBitmap |= _getRoleValue(contractKey, roleNames[i]);
        }

        string memory label = string.concat(granteeKey, " roles on ", contractKey);

        // Check 1: On-chain bitmap matches expected roles
        if (actualBitmap != expectedBitmap) {
            console2.log(string.concat("*** ERROR *** ", label, " = %x; expected = %x"), actualBitmap, expectedBitmap);
            return;
        }

        // TODO: this doesn't work for pegged as it is deployed separately
        // if we separate the datastores and have one for minter and for pegged then we can look in each of the data stores
        // until then this part if disabled
        // // Check 2: Verify recorded grantees match for each role
        // for (uint256 i = 0; i < roleNames.length; i++) {
        //     string[] memory grantees = _getRoleGrantees(contractKey, roleNames[i]);
        //     bool found = false;
        //     for (uint256 j = 0; j < grantees.length; j++) {
        //         if (LibString.eq(grantees[j], granteeKey)) {
        //             found = true;
        //             break;
        //         }
        //     }
        //     if (!found) {
        //         console2.log(
        //             string.concat(
        //                 "*** ERROR *** ",
        //                 granteeKey,
        //                 " not recorded as grantee of ",
        //                 roleNames[i],
        //                 " on ",
        //                 contractKey
        //             )
        //         );
        //         return;
        //     }
        // }

        console2.log(string.concat(unicode"✓ ", label, " = %x"), actualBitmap);
    }

    // ============================================================================
    // Role Management
    // ============================================================================

    /// @notice Build the role key from contract key and role name
    /// @dev Returns "{contractKey}.roles.{roleName}" (e.g., "contracts.pegged.roles.MINTER_ROLE")
    function _roleKey(string memory contractKey, string memory roleName) internal pure returns (string memory) {
        return string.concat(contractKey, ".roles.", roleName);
    }

    /// @notice Set a role's value for a contract
    /// @dev Reverts if key not registered (explicit). Reverts if a different value is already set.
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    /// @param value The role's uint256 bitmask value
    function _setRole(string memory contractKey, string memory roleName, uint256 value) internal {
        string memory roleKey = _roleKey(contractKey, roleName);
        string memory valueKey = string.concat(roleKey, ".value");

        // Check if already has a value with different value
        if (_hasKey[valueKey]) {
            uint256 existingValue = _uints[valueKey];
            if (existingValue != value) {
                revert RoleValueMismatch(roleKey, existingValue, value);
            }
            // Same value, no-op
            return;
        }

        // Set value and initialize empty grantees (validateKey happens in _setUint/_setStringArray)
        _setUint(valueKey, value);
        _setStringArray(string.concat(roleKey, ".grantees"), new string[](0));
    }

    /// @notice Add a grantee for a role
    /// @dev Reverts if the grantee is already registered for this role
    /// @param granteeKey The grantee's contract key (e.g., "contracts.minter")
    /// @param contractKey The contract key where the role is defined (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    function _setGrantee(string memory granteeKey, string memory contractKey, string memory roleName) internal {
        string memory roleKey = _roleKey(contractKey, roleName);
        string memory granteesKey = string.concat(roleKey, ".grantees");

        // Get current grantees
        string[] memory currentGrantees = _stringArrays[granteesKey];

        // Check for duplicate grantee
        for (uint256 i = 0; i < currentGrantees.length; i++) {
            if (LibString.eq(currentGrantees[i], granteeKey)) {
                revert DuplicateGrantee(roleKey, granteeKey);
            }
        }

        // Append to grantees array
        _stringArrays[granteesKey].push(granteeKey);
        _afterValueChanged(granteesKey);
    }

    /// @notice Get the role value for a contract's role
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    /// @return value The role's uint256 bitmask value
    function _getRoleValue(string memory contractKey, string memory roleName) internal view returns (uint256) {
        return _getUint(string.concat(_roleKey(contractKey, roleName), ".value"));
    }

    /// @notice Check if a role value is set
    function _hasRole(string memory contractKey, string memory roleName) internal view returns (bool) {
        return _hasKey[string.concat(_roleKey(contractKey, roleName), ".value")];
    }

    /// @notice Get the grantees for a contract's role
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param roleName The role name (e.g., "MINTER_ROLE")
    /// @return grantees Array of grantee contract keys
    function _getRoleGrantees(
        string memory contractKey,
        string memory roleName
    ) internal view returns (string[] memory) {
        return _getStringArray(string.concat(_roleKey(contractKey, roleName), ".grantees"));
    }

    /// @notice Get role names for a contract by scanning data keys
    /// @dev Scans keys() for keys matching {contractKey}.roles.*.value and extracts role names
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @return roleNames Array of role names with values set for this contract
    function _getContractRoleNames(string memory contractKey) internal view returns (string[] memory) {
        string memory prefix = string.concat(contractKey, ".roles.");
        string memory suffix = ".value";
        string[] memory allKeys = keys(); // Use data keys, not schema keys

        // Count matching keys
        uint256 count = 0;
        for (uint256 i = 0; i < allKeys.length; i++) {
            if (LibString.startsWith(allKeys[i], prefix) && LibString.endsWith(allKeys[i], suffix)) {
                count++;
            }
        }

        // Extract role names
        string[] memory roleNames = new string[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < allKeys.length; i++) {
            string memory key = allKeys[i];
            if (LibString.startsWith(key, prefix) && LibString.endsWith(key, suffix)) {
                // Extract role name: remove prefix and suffix
                // key = "contracts.pegged.roles.MINTER_ROLE.value"
                // prefix = "contracts.pegged.roles."
                // suffix = ".value"
                uint256 prefixLen = bytes(prefix).length;
                uint256 suffixLen = bytes(suffix).length;
                uint256 keyLen = bytes(key).length;
                roleNames[j++] = LibString.slice(key, prefixLen, keyLen - suffixLen);
            }
        }
        return roleNames;
    }

    /// @notice Compute the expected role bitmap for a grantee on a contract
    /// @dev Iterates all roles on contractKey and ORs values where granteeKey is a grantee
    /// @param contractKey The contract key (e.g., "contracts.pegged")
    /// @param granteeKey The grantee's contract key (e.g., "contracts.minter")
    /// @return bitmap The combined role bitmap
    function _computeExpectedRoles(
        string memory contractKey,
        string memory granteeKey
    ) internal view returns (uint256 bitmap) {
        string[] memory roleNames = _getContractRoleNames(contractKey);
        for (uint256 i = 0; i < roleNames.length; i++) {
            string[] memory grantees = _getRoleGrantees(contractKey, roleNames[i]);
            for (uint256 j = 0; j < grantees.length; j++) {
                if (LibString.eq(grantees[j], granteeKey)) {
                    bitmap |= _getRoleValue(contractKey, roleNames[i]);
                    break;
                }
            }
        }
    }
}
