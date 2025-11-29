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
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";

interface IUUPSUpgradeableProxy {
    function implementation() external view returns (address);
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

/**
 * @title Deployment
 * @notice Deployment operations using composition-based data layer
 * @dev Responsibilities:
 *      - Deterministic proxy deployment via CREATE3
 *      - Library deployment via CREATE
 *      - Existing contract registration helpers
 *      - All state managed through IDeploymentDataWritable
 *      - Designed for specialization (e.g. Harbor overrides deployProxy)
 */

abstract contract Deployment is DeploymentKeys {
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
    // Storage
    // ============================================================================

    /// @notice Data layer holding all configuration and deployment state
    /// @dev Composition pattern: allows swapping implementations (JSON, Memory, etc.)
    ///      Protected to allow subclass access while enforcing wrapper methods for contracts.
    IDeploymentDataWritable internal _data;

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

    function _createDeploymentData(
        string memory /*network*/,
        string memory /*systemSaltString*/,
        string memory /*inputTimestamp*/
    ) internal virtual returns (IDeploymentDataWritable);

    /// @notice Start deployment session
    /// @dev Subclasses must call _startWithDataLayer after creating data layer
    /// @param network Network name (e.g., "mainnet", "arbitrum", "anvil")
    /// @param systemSaltString System salt string for deterministic addresses
    function start(string memory network, string memory systemSaltString, string memory startPoint) public virtual {
        if (_sessionState != State.NONE) revert AlreadyInitialized();

        _data = _createDeploymentData(network, systemSaltString, startPoint);
        // TODO: need to read the schema version and check for compatibility
        // Set global deployment configuration
        _data.setUint(SCHEMA_VERSION, 1);
        _data.setString(SYSTEM_SALT_STRING, systemSaltString);

        // Initialize session metadata
        _data.setString(SESSION_NETWORK, network);
        _data.setAddress(SESSION_DEPLOYER, address(this));
        _data.setUint(SESSION_START_TIMESTAMP, block.timestamp);
        _data.setUint(SESSION_START_BLOCK, block.number);

        // Set up deployment infrastructure
        _ensureBaoDeployerOperator();
        _stub = new UUPSProxyDeployStub();

        _sessionState = State.STARTED;
    }

    /// @notice Finish deployment session
    /// @dev Transfers ownership to final owner for all proxies, marks session complete
    /// @return transferred Number of proxies whose ownership was transferred
    function finish() public virtual returns (uint256 transferred) {
        if (_sessionState == State.NONE) revert SessionNotStarted();
        if (_sessionState == State.FINISHED) revert SessionAlreadyFinished();

        // Transfer ownership for all deployed proxies
        // Note: This is a simplified implementation - production may need to track proxy list
        // For now, we rely on subclasses to call _transferProxyOwnership for each proxy

        // Mark session finished using registered keys
        _data.setUint(SESSION_FINISH_TIMESTAMP, block.timestamp);
        _data.setUint(SESSION_FINISH_BLOCK, block.number);
        _sessionState = State.FINISHED;

        return transferred;
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
        address finalOwner = _data.getAddress(OWNER);

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
    function _registerProxy(
        string memory proxyKey,
        address proxy,
        address factory,
        bytes32 salt,
        address deployer
    ) private {
        // register keys
        // the proxy
        _registerImplementation(
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
        } else if ((implementationInitData.length == 0) && (value == 0)) {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall{value: value}(newImplementation, implementationInitData);
        }

        // implementation keys
        string memory implementationKey = string.concat(proxyKey, ".implementation");
        _registerImplementation(
            implementationKey,
            newImplementation,
            implementationContractType,
            implementationContractPath,
            deployer
        );
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

        _registerImplementation(key, addr, contractType, contractPath, deployer);
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

    function registerContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) public {
        _requireActiveRun();
        _registerImplementation(key, addr, contractType, contractPath, deployer);
        _setString(string.concat(key, ".category"), "contract");
    }

    function _registerImplementation(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        address deployer
    ) private {
        _set(key, addr);
        _setAddress(string.concat(key, ".address"), addr);
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

        // TODO: fix these keys
        _set(key, addr);
        _setAddress(string.concat(key, ".address"), addr);
        _setString(string.concat(key, ".category"), "library");
        _setString(string.concat(key, ".contractType"), contractType);
        _setString(string.concat(key, ".contractPath"), contractPath);
        _setAddress(string.concat(key, ".deployer"), deployer);
        _setUint(string.concat(key, ".blockNumber"), block.number);
    }

    function _afterValueChanged(string memory key) internal virtual;

    /// @notice Set contract address
    function _set(string memory key, address value) internal {
        _data.set(key, value);
        _afterValueChanged(key);
    }

    /// @notice Get contract address
    function _get(string memory key) internal view returns (address) {
        return _data.get(key);
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
    function _has(string memory key) internal view returns (bool) {
        return _data.has(key);
    }

    /// @notice Set string value
    function _setString(string memory key, string memory value) internal {
        _data.setString(key, value);
        _afterValueChanged(key);
    }

    /// @notice Get string value
    function _getString(string memory key) internal view returns (string memory) {
        return _data.getString(key);
    }

    /// @notice Set uint value
    function _setUint(string memory key, uint256 value) internal {
        _data.setUint(key, value);
        _afterValueChanged(key);
    }

    /// @notice Get uint value
    function _getUint(string memory key) internal view returns (uint256) {
        return _data.getUint(key);
    }

    /// @notice Set int value
    function _setInt(string memory key, int256 value) internal {
        _data.setInt(key, value);
        _afterValueChanged(key);
    }

    /// @notice Get int value
    function _getInt(string memory key) internal view returns (int256) {
        return _data.getInt(key);
    }

    /// @notice Set bool value
    function _setBool(string memory key, bool value) internal {
        _data.setBool(key, value);
        _afterValueChanged(key);
    }

    /// @notice Get bool value
    function _getBool(string memory key) internal view returns (bool) {
        return _data.getBool(key);
    }

    function _setAddress(string memory key, address value) internal {
        _data.setAddress(key, value);
        _afterValueChanged(key);
    }

    function _getAddress(string memory key) internal view returns (address) {
        return _data.getAddress(key);
    }

    /// @notice Set address array
    function _setAddressArray(string memory key, address[] memory values) internal {
        _data.setAddressArray(key, values);
        _afterValueChanged(key);
    }

    /// @notice Get address array
    function _getAddressArray(string memory key) internal view returns (address[] memory) {
        return _data.getAddressArray(key);
    }

    /// @notice Set string array
    function _setStringArray(string memory key, string[] memory values) internal {
        _data.setStringArray(key, values);
        _afterValueChanged(key);
    }

    /// @notice Get string array
    function _getStringArray(string memory key) internal view returns (string[] memory) {
        return _data.getStringArray(key);
    }

    /// @notice Set uint array
    function _setUintArray(string memory key, uint256[] memory values) internal {
        _data.setUintArray(key, values);
        _afterValueChanged(key);
    }

    /// @notice Get uint array
    function _getUintArray(string memory key) internal view returns (uint256[] memory) {
        return _data.getUintArray(key);
    }

    /// @notice Set int array
    function _setIntArray(string memory key, int256[] memory values) internal {
        _data.setIntArray(key, values);
        _afterValueChanged(key);
    }

    /// @notice Get int array
    function _getIntArray(string memory key) internal view returns (int256[] memory) {
        return _data.getIntArray(key);
    }

    /// @notice Derive system salt for deterministic address calculations
    /// @dev Subclasses can override to customize salt derivation (e.g., network-specific tweaks)
    function _deriveSystemSalt() internal view virtual returns (string memory) {
        return _data.getString(SYSTEM_SALT_STRING);
    }
}
