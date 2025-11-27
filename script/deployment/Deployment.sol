// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";

interface IUUPSUpgradeableProxy {
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
    bool internal _sessionActive;

    /// @notice Session finished flag
    bool internal _sessionFinished;

    // ============================================================================
    // Factory Abstraction
    // ============================================================================

    /// @notice Get the deployer address for CREATE3 operations
    /// @dev Returns BaoDeployer address - same on all chains (deployed via Nick's Factory)
    ///      This is used for both prediction and deployment
    /// @return deployer BaoDeployer contract address
    function _getCreate3Deployer() internal view virtual returns (address deployer) {
        deployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (deployer == address(0)) {
            revert FactoryDeploymentFailed("BaoDeployer owner not configured");
        }
    }

    /// @notice Require that this deployment harness is configured as BaoDeployer operator
    /// @dev Production check - reverts if operator not already configured by multisig
    ///      Testing classes override this to auto-setup operator via VM.prank
    function _requireBaoDeployerOperator() internal virtual {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (baoDeployer.code.length == 0) {
            revert FactoryDeploymentFailed("BaoDeployer missing code");
        }
        if (BaoDeployer(baoDeployer).operator() != address(this)) {
            revert FactoryDeploymentFailed("BaoDeployer operator not configured for harness");
        }
    }

    // ============================================================================
    // Deployment Lifecycle
    // ============================================================================

    function _createDeploymentData(
        string memory /*network*/,
        string memory /*systemSaltString*/,
        string memory /*inputTimestamp*/
    ) internal virtual returns (IDeploymentDataWritable) {
        return new DeploymentDataMemory(this);
    }

    /// @notice Start deployment session
    /// @dev Subclasses must call _startWithDataLayer after creating data layer
    /// @param network Network name (e.g., "mainnet", "arbitrum", "anvil")
    /// @param systemSaltString System salt string for deterministic addresses
    function start(string memory network, string memory systemSaltString, string memory startPoint) public {
        require(!_sessionActive, "Session already started");

        _data = _createDeploymentData(network, systemSaltString, startPoint);

        // Set global deployment configuration
        _data.setString(SYSTEM_SALT_STRING, systemSaltString);

        // Initialize session metadata
        _data.setString(SESSION_NETWORK, network);
        _data.setAddress(SESSION_DEPLOYER, address(this));
        _data.setUint(SESSION_START_TIMESTAMP, block.timestamp);
        _data.setUint(SESSION_START_BLOCK, block.number);

        // Set up deployment infrastructure
        _requireBaoDeployerOperator();
        _stub = new UUPSProxyDeployStub();

        _sessionActive = true;
    }

    /// @notice Finish deployment session
    /// @dev Transfers ownership to final owner for all proxies, marks session complete
    /// @return transferred Number of proxies whose ownership was transferred
    function finish() public virtual returns (uint256 transferred) {
        if (!_sessionActive) revert SessionNotStarted();
        if (_sessionFinished) revert SessionAlreadyFinished();

        // Transfer ownership for all deployed proxies
        // Note: This is a simplified implementation - production may need to track proxy list
        // For now, we rely on subclasses to call _transferProxyOwnership for each proxy

        // Mark session finished using registered keys
        _data.setUint(SESSION_FINISH_TIMESTAMP, block.timestamp);
        _data.setUint(SESSION_FINISH_BLOCK, block.number);
        _sessionFinished = true;

        return transferred;
    }

    function dataStore() public view returns (address) {
        return address(_data);
    }

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
    /// @return deployed BaoDeployer address
    function deployBaoDeployer() public returns (address deployed) {
        deployed = DeploymentInfrastructure.deployBaoDeployer();
        if (_sessionActive) {
            useExisting("BaoDeployer", deployed);
        }
    }

    // ============================================================================
    // Data Layer Wrappers (add "contracts." prefix)
    // ============================================================================

    function _contractsKey(string memory key) private pure returns (string memory) {
        return string.concat(CONTRACTS_PREFIX, key);
    }

    /// @notice Set contract address
    /// @dev Adds "contracts." prefix: "pegged" → "contracts.pegged"
    function _set(string memory key, address value) internal {
        _data.set(_contractsKey(key), value);
    }

    /// @notice Get contract address
    /// @dev Adds "contracts." prefix: "pegged" → "contracts.pegged"
    function _get(string memory key) internal view returns (address) {
        return _data.get(_contractsKey(key));
    }

    /// @notice Check if contract key exists
    /// @dev Adds "contracts." prefix
    function _has(string memory key) internal view returns (bool) {
        return _data.has(_contractsKey(key));
    }

    /// @notice Set string value
    /// @dev Adds "contracts." prefix: "pegged.symbol" → "contracts.pegged.symbol"
    function _setString(string memory key, string memory value) internal {
        _data.setString(_contractsKey(key), value);
    }

    /// @notice Get string value
    /// @dev Adds "contracts." prefix
    function _getString(string memory key) internal view returns (string memory) {
        return _data.getString(_contractsKey(key));
    }

    /// @notice Set uint value
    /// @dev Adds "contracts." prefix
    function _setUint(string memory key, uint256 value) internal {
        _data.setUint(_contractsKey(key), value);
    }

    /// @notice Get uint value
    /// @dev Adds "contracts." prefix
    function _getUint(string memory key) internal view returns (uint256) {
        return _data.getUint(_contractsKey(key));
    }

    /// @notice Set int value
    /// @dev Adds "contracts." prefix
    function _setInt(string memory key, int256 value) internal {
        _data.setInt(_contractsKey(key), value);
    }

    /// @notice Get int value
    /// @dev Adds "contracts." prefix
    function _getInt(string memory key) internal view returns (int256) {
        return _data.getInt(_contractsKey(key));
    }

    /// @notice Set bool value
    /// @dev Adds "contracts." prefix
    function _setBool(string memory key, bool value) internal {
        _data.setBool(_contractsKey(key), value);
    }

    /// @notice Get bool value
    /// @dev Adds "contracts." prefix
    function _getBool(string memory key) internal view returns (bool) {
        return _data.getBool(_contractsKey(key));
    }

    function _setAddress(string memory key, address value) internal {
        _data.setAddress(_contractsKey(key), value);
    }

    function _getAddress(string memory key) internal view returns (address) {
        return _data.getAddress(_contractsKey(key));
    }

    /// @notice Set address array
    /// @dev Adds "contracts." prefix
    function _setAddressArray(string memory key, address[] memory values) internal {
        _data.setAddressArray(_contractsKey(key), values);
    }

    /// @notice Get address array
    /// @dev Adds "contracts." prefix
    function _getAddressArray(string memory key) internal view returns (address[] memory) {
        return _data.getAddressArray(_contractsKey(key));
    }

    /// @notice Set string array
    /// @dev Adds "contracts." prefix
    function _setStringArray(string memory key, string[] memory values) internal {
        _data.setStringArray(_contractsKey(key), values);
    }

    /// @notice Get string array
    /// @dev Adds "contracts." prefix
    function _getStringArray(string memory key) internal view returns (string[] memory) {
        return _data.getStringArray(_contractsKey(key));
    }

    /// @notice Set uint array
    /// @dev Adds "contracts." prefix
    function _setUintArray(string memory key, uint256[] memory values) internal {
        _data.setUintArray(_contractsKey(key), values);
    }

    /// @notice Get uint array
    /// @dev Adds "contracts." prefix
    function _getUintArray(string memory key) internal view returns (uint256[] memory) {
        return _data.getUintArray(_contractsKey(key));
    }

    /// @notice Set int array
    /// @dev Adds "contracts." prefix
    function _setIntArray(string memory key, int256[] memory values) internal {
        _data.setIntArray(_contractsKey(key), values);
    }

    /// @notice Get int array
    /// @dev Adds "contracts." prefix
    function _getIntArray(string memory key) internal view returns (int256[] memory) {
        return _data.getIntArray(_contractsKey(key));
    }

    /// @notice Derive system salt for deterministic address calculations
    /// @dev Subclasses can override to customize salt derivation (e.g., network-specific tweaks)
    function _deriveSystemSalt() internal view virtual returns (string memory) {
        return _data.getString(SYSTEM_SALT_STRING);
    }

    // ============================================================================
    // Proxy Deployment / Upgrades
    // ============================================================================

    /// @notice Predict proxy address without deploying
    /// @param proxyKey Key for the proxy deployment
    /// @return proxy Predicted proxy address
    function predictProxyAddress(string memory proxyKey) public view returns (address proxy) {
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
        string memory implementationKey,
        bytes memory implementationInitData
    ) external payable virtual returns (address proxy) {
        if (msg.value != value) {
            revert ValueMismatch(value, msg.value);
        }
        proxy = _deployProxy(value, proxyKey, implementationKey, implementationInitData);
    }

    /// @notice Deploy a UUPS proxy using bootstrap stub pattern
    /// @dev Three-step process:
    ///      1. Deploy ERC1967Proxy via CREATE3 pointing to stub (no initialization)
    ///      2. Call proxy.upgradeToAndCall(implementation, initData) to atomically upgrade and initialize
    ///      During initialization, msg.sender = this harness (via stub ownership), enabling BaoOwnable compatibility
    /// @param proxyKey Key for the proxy deployment
    /// @param implementationKey Key of the implementation to use
    /// @param implementationInitData Initialization data to pass to implementation (includes owner if needed)
    /// @return proxy The deployed proxy address
    function deployProxy(
        string memory proxyKey,
        string memory implementationKey,
        bytes memory implementationInitData
    ) external virtual returns (address proxy) {
        proxy = _deployProxy(0, proxyKey, implementationKey, implementationInitData);
    }

    function _deployProxy(
        uint256 value,
        string memory proxyKey,
        string memory implementationKey,
        bytes memory implementationInitData
    ) internal virtual returns (address proxy) {
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        if (bytes(implementationKey).length == 0) {
            revert ImplementationKeyRequired();
        }

        // Check implementation exists
        if (!_has(implementationKey)) {
            revert ImplementationKeyRequired();
        }
        address implementation = _get(implementationKey);
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

        BaoDeployer deployer = BaoDeployer(factory);
        bytes32 commitment = DeploymentInfrastructure.commitment(
            address(this),
            0,
            salt,
            EfficientHashLib.hash(proxyCreationCode)
        );
        deployer.commit(commitment);
        proxy = deployer.reveal(proxyCreationCode, salt, 0);

        if (value == 0) {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(implementation, implementationInitData);
        } else {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall{value: value}(implementation, implementationInitData);
        }

        // Store proxy address and metadata in data layer
        _set(proxyKey, proxy);
        _setString(string.concat(proxyKey, ".implementation"), implementationKey);
        _setString(string.concat(proxyKey, ".category"), "proxy");
    }

    /// @notice Upgrade existing proxy to new implementation
    function upgradeProxy(
        string memory proxyKey,
        string memory newImplementationKey,
        bytes memory initData
    ) external virtual {
        if (bytes(proxyKey).length == 0 || bytes(newImplementationKey).length == 0) {
            revert KeyRequired();
        }

        // Check proxy and implementation exist
        require(_has(proxyKey), "Proxy not found");
        require(_has(newImplementationKey), "Implementation not found");

        address proxy = _get(proxyKey);
        address newImplementation = _get(newImplementationKey);

        require(proxy != address(0), "Proxy address is zero");
        require(newImplementation != address(0), "Implementation address is zero");

        // Perform the upgrade
        if (initData.length == 0) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
        } else {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(newImplementation, initData);
        }

        // Update implementation reference in data layer
        _setString(string.concat(proxyKey, ".implementation"), newImplementationKey);
    }

    /// @notice Register existing contract address
    function useExisting(string memory key, address addr) public virtual {
        _set(key, addr);
        _setString(string.concat(key, ".category"), "existing");
    }

    /**
     * @notice Register implementation with key derived from proxy key and contract type
     * @dev Implementation key pattern: proxyKey__contractType
     *      This ensures consistent implementation key generation across all deployers
     * @param proxyKey The proxy key this implementation is for
     * @param addr Implementation contract address
     * @param contractType Contract type name (used in key derivation)
     * @param contractPath Source file path (stored in data layer for reference)
     * @return implKey The derived implementation key (proxyKey__contractType)
     */
    function registerImplementation(
        string memory proxyKey,
        address addr,
        string memory contractType,
        string memory contractPath
    ) public virtual returns (string memory implKey) {
        implKey = _deriveImplementationKey(proxyKey, contractType);

        // Store implementation address in data layer
        _set(implKey, addr);

        // Optionally store metadata
        _setString(string.concat(implKey, ".type"), contractType);
        _setString(string.concat(implKey, ".path"), contractPath);
    }

    /// @notice Derive the canonical implementation key for a proxy key and contract type
    function _deriveImplementationKey(
        string memory proxyKey,
        string memory contractType
    ) internal pure returns (string memory) {
        return string.concat(proxyKey, "__", contractType);
    }

    /// @notice Deploy library using CREATE
    function deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) public {
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        if (addr == address(0)) {
            revert LibraryDeploymentFailed(key);
        }

        _set(key, addr);
        _setString(string.concat(key, ".category"), "library");
        _setString(string.concat(key, ".type"), contractType);
        _setString(string.concat(key, ".path"), contractPath);
    }

    // ============================================================================
    // Internal Helpers
    // ============================================================================

    /**
     * @notice Internal helper for string comparison
     */
    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
