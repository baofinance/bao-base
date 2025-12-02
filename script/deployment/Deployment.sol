// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {console2} from "forge-std/console2.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";
import {Create3CommitFlow} from "@bao-script/deployment/Create3CommitFlow.sol";

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
    function _startBroadcast() internal virtual {}

    /// @notice Hook called after blockchain operations
    /// @dev Override in script classes to call vm.stopBroadcast()
    ///      Default is no-op (works for tests where no broadcast is needed)
    function _stopBroadcast() internal virtual {}

    // ============================================================================
    // Deployment Lifecycle
    // ============================================================================

    /// @notice Start deployment session
    /// @dev Subclasses can override for custom initialization (e.g., JSON loading)
    /// @param network Network name (e.g., "mainnet", "arbitrum", "anvil")
    /// @param systemSaltString System salt string for deterministic addresses
    /// @param deployer Address that will sign transactions (EOA for scripts, harness for tests)
    function start(
        string memory network,
        string memory systemSaltString,
        address deployer,
        string memory /* startPoint */
    ) public virtual {
        if (_sessionState != State.NONE) revert AlreadyInitialized();

        // TODO: need to read the schema version and check for compatibility
        // Set global deployment configuration
        _setUint(SCHEMA_VERSION, 1);
        _setString(SYSTEM_SALT_STRING, systemSaltString);

        // Initialize session metadata
        _setString(SESSION_NETWORK, network);
        _setAddress(SESSION_DEPLOYER, deployer);
        console2.log("deployer = %s", deployer);
        _setUint(SESSION_START_TIMESTAMP, block.timestamp);
        _setString(SESSION_STARTED, _formatTimestamp(block.timestamp));
        _setUint(SESSION_START_BLOCK, block.number);

        _startBroadcast();
        // Set up deployment infrastructure
        // in all scenarios we can deploy it
        address baoDeployer = DeploymentInfrastructure.ensureBaoDeployer();
        console2.log("BaoDeployer = %s", baoDeployer);
        _setAddress(BAO_FACTORY, baoDeployer);
        // if it is not set up sometimes we can't continue
        // in dev we can prank and setOperator
        // in prod we can't so we fail here
        console2.log("BaoDeployer operator = %s", BaoDeployer(baoDeployer).operator());
        if (BaoDeployer(baoDeployer).operator() != _getAddress(SESSION_DEPLOYER)) {
            revert FactoryDeploymentFailed("BaoDeployer operator not configured for this deployer");
        }

        // Deploy stub (testing classes override, scripts use setStub before start)
        UUPSProxyDeployStub stub = new UUPSProxyDeployStub();
        console2.log("UUPSProxyDeployStub = %s", address(stub));
        console2.log("UUPSProxyDeployStub.owner() = %s", stub.owner());
        _set(SESSION_STUB, address(stub));
        _setString(SESSION_STUB_CONTRACT_TYPE, "UUPSProxyDeployStub");
        _setString(SESSION_STUB_CONTRACT_PATH, "script/deployment/UUPSProxyDeployStub.sol");
        _setUint(SESSION_STUB_BLOCK_NUMBER, block.number);

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

        // Transfer ownership (needs broadcast in script context)
        for (uint256 i; i < proxies.length; i++) {
            TransferrableProxy memory tp = proxies[i];
            IBaoOwnable(tp.proxy).transferOwnership(tp.configuredOwner);
        }

        // Update metadata after blockchain operations
        for (uint256 i; i < proxies.length; i++) {
            TransferrableProxy memory tp = proxies[i];
            _setString(string.concat(tp.parentKey, ".implementation.ownershipModel"), "transferred-after-deploy");
        }

        // Mark session finished (use _set* to trigger _afterValueChanged for persistence)
        _setUint(SESSION_FINISH_TIMESTAMP, block.timestamp);
        _setString(SESSION_FINISHED, _formatTimestamp(block.timestamp));
        _setUint(SESSION_FINISH_BLOCK, block.number);
        _sessionState = State.FINISHED;

        _stopBroadcast();

        return transferred;
    }

    /// @notice Get list of proxies needing ownership transfer
    /// @dev Finds all keys ending in ".implementation.ownershipModel" with value "transfer-after-deploy"
    ///      Performs runtime ownership check - only returns proxies where currentOwner != configuredOwner
    /// @return proxies Array of TransferrableProxy structs (only those actually needing transfer)
    function _getTransferrableProxies() internal view returns (TransferrableProxy[] memory proxies) {
        address globalOwner = _getAddress(OWNER);
        string[] memory allKeys = keys();
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
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        proxy = CREATE3.predictDeterministicAddress(salt, baoDeployer);
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
            abi.encode(_get(SESSION_STUB), bytes(""))
        );

        BaoDeployer baoDeployer = BaoDeployer(factory);

        bytes32 commitment = DeploymentInfrastructure.commitment(
            _getAddress(SESSION_DEPLOYER),
            0,
            salt,
            EfficientHashLib.hash(proxyCreationCode)
        );

        // Deploy proxy via CREATE3 (needs broadcast in script context)
        baoDeployer.commit(commitment);
        address proxy = baoDeployer.reveal(proxyCreationCode, salt, 0);

        // Register proxy with all metadata (extracted to avoid stack too deep)
        _recordProxy(proxyKey, proxy, factory, salt, deployer, block.number);

        _recordContractFields(
            string.concat(proxyKey, ".implementation"),
            _get(SESSION_STUB),
            _getString(SESSION_STUB_CONTRACT_TYPE),
            _getString(SESSION_STUB_CONTRACT_PATH),
            _getAddress(SESSION_DEPLOYER),
            _getUint(SESSION_STUB_BLOCK_NUMBER)
        );

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
    function _recordProxy(
        string memory proxyKey,
        address proxy,
        address factory,
        bytes32 salt,
        address deployer,
        uint256 blockNumber
    ) private {
        // register keys
        // the proxy
        _recordContractFields(
            proxyKey,
            proxy,
            "ERC1967Proxy",
            "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol",
            deployer,
            blockNumber
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

        // Perform the upgrade (needs broadcast in script context)
        if ((implementationInitData.length == 0) && (value == 0)) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
        } else if ((implementationInitData.length == 0) && (value != 0)) {
            _stopBroadcast();
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
            deployer,
            block.number
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

        Create3CommitFlow.Request memory request = Create3CommitFlow.Request({
            operator: _getAddress(SESSION_DEPLOYER),
            systemSaltString: _getString(SYSTEM_SALT_STRING),
            key: key,
            initCode: initCode,
            value: value
        });

        // Deploy via CREATE3 (needs broadcast in script context)
        (address addr, , address factory) = Create3CommitFlow.commitAndReveal(
            request,
            Create3CommitFlow.RevealMode.MatchValue
        );
        _stopBroadcast();

        _recordContractFields(key, addr, contractType, contractPath, deployer, block.number);
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
        _recordContractFields(key, addr, contractType, contractPath, deployer, block.number);
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
        _recordContractFields(
            implKey,
            implAddress,
            contractType,
            contractPath,
            _getAddress(SESSION_DEPLOYER),
            block.number
        );
        _setString(string.concat(implKey, ".ownershipModel"), ownershipModel);
    }

    /// @dev Record common contract metadata fields
    function _recordContractFields(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer,
        uint256 blockNumber
    ) private {
        _set(key, addr);
        _setString(string.concat(key, ".contractType"), contractType);
        _setString(string.concat(key, ".contractPath"), contractPath);
        _setAddress(string.concat(key, ".deployer"), deployer);
        _setUint(string.concat(key, ".blockNumber"), blockNumber);
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

        // Deploy library (needs broadcast in script context)
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        _stopBroadcast();

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

    // Note: keys() and schemaKeys() are inherited from DeploymentDataMemory/DeploymentKeys

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

    /// @notice Derive system salt for deterministic address calculations
    /// @dev Subclasses can override to customize salt derivation (e.g., network-specific tweaks)
    function _deriveSystemSalt() internal view virtual returns (string memory) {
        return _getString(SYSTEM_SALT_STRING);
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
