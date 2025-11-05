// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

interface IUUPSUpgradeableProxy {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
}

/**
 * @title Deployment
 * @notice Deployment operations layer built on top of DeploymentRegistry
 * @dev Responsibilities:
 *      - Deterministic proxy deployment via CREATE3
 *      - Library deployment via CREATE
 *      - Existing contract registration helpers
 *      - Thin wrappers around registry storage helpers
 *      - Designed for specialization (e.g. Harbor overrides deployProxy)
 * @dev Cross-chain determinism is achieved through injected deployer context:
 *      - Production: Pass the harness address deployed via Nick's Factory
 *      - Testing: Pass address(0) to default to address(this)
 */
abstract contract Deployment is DeploymentJson {
    // ============================================================================
    // Immutables
    // ============================================================================

    /// @notice Deployer context address used for CREATE3 determinism
    /// @dev In production, this is the harness address deployed via Nick's Factory.
    ///      In tests, this defaults to address(this) when address(0) is passed.
    address internal immutable DEPLOYER_CONTEXT;

    // ============================================================================
    // Storage
    // ============================================================================

    /// @notice Bootstrap stub used as initial implementation for all proxies
    /// @dev Deployed once per session, owned by this harness, enables BaoOwnable compatibility with CREATE3
    UUPSProxyDeployStub internal _stub;

    // ============================================================================
    // Constants
    // ============================================================================

    /// Nick's Factory address (deployed on 100+ chains)
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Nick's Factory bytecode for test environments
    /// Source: https://github.com/Vectorized/solady/blob/main/test/utils/TestPlus.sol
    bytes internal constant NICKS_FACTORY_BYTECODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    /// Salt for deploying BaoDeployer via Nick's Factory
    /// This ensures BaoDeployer has the same address on all chains
    bytes32 internal constant BAO_DEPLOYER_SALT = keccak256("Bao.deterministic-deployer.harbor.v1");

    // ============================================================================
    // BaoDeployer Helpers
    // ============================================================================

    /// @notice Get the deterministic BaoDeployer proxy address
    /// @dev Computes address of the ERC1967Proxy that wraps the BaoDeployer implementation
    /// @dev Proxy is deployed WITHOUT init data for determinism - initialize() called separately
    /// @return deployer BaoDeployer proxy address (same on all chains)
    function _getBaoDeployerAddress() internal pure returns (address deployer) {
        // Step 1: Compute implementation address
        bytes32 implBytecodeHash = keccak256(type(BaoDeployer).creationCode);
        bytes32 implSalt = keccak256(abi.encodePacked(BAO_DEPLOYER_SALT, ".implementation"));
        address implementation = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), NICKS_FACTORY, implSalt, implBytecodeHash))))
        );

        // Step 2: Compute proxy address (NO init data for determinism)
        bytes memory proxyCreationCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(implementation, "") // Empty init data
        );
        bytes32 proxyBytecodeHash = keccak256(proxyCreationCode);
        bytes32 proxyHash = keccak256(
            abi.encodePacked(bytes1(0xff), NICKS_FACTORY, BAO_DEPLOYER_SALT, proxyBytecodeHash)
        );
        return address(uint160(uint256(proxyHash)));
    }

    /// @notice Check if BaoDeployer exists
    /// @return True if BaoDeployer has code at the expected address
    function _baoDeployerExists() internal view returns (bool) {
        return _getBaoDeployerAddress().code.length > 0;
    }

    /// @notice Deploy BaoDeployer via Nick's Factory if it doesn't exist
    /// @dev This function is reusable for both production and test deployments
    /// @param owner Address that will own the BaoDeployer
    /// @param initialDeployers Array of addresses to grant DEPLOYER_ROLE
    /// @return deployed Address of the BaoDeployer (whether newly deployed or existing)
    function _deployBaoDeployer(address owner, address[] memory initialDeployers) internal returns (address deployed) {
        deployed = _getBaoDeployerAddress();

        // Only deploy if it doesn't exist
        if (!_baoDeployerExists()) {
            address factory = NICKS_FACTORY;

            // Step 1: Deploy the implementation contract via CREATE2
            bytes memory implCreationCode = type(BaoDeployer).creationCode;
            bytes32 implSalt = keccak256(abi.encodePacked(BAO_DEPLOYER_SALT, ".implementation"));
            address implementation;

            /// @solidity memory-safe-assembly
            assembly {
                let n := mload(implCreationCode)
                mstore(implCreationCode, implSalt)
                if iszero(call(gas(), factory, 0, implCreationCode, add(n, 0x20), 0x00, 0x20)) {
                    returndatacopy(implCreationCode, 0x00, returndatasize())
                    revert(implCreationCode, returndatasize())
                }
                mstore(implCreationCode, n)
                implementation := shr(96, mload(0x00))
            }

            require(implementation.code.length > 0, "BaoDeployer implementation has no code");

            // Step 2: Deploy the proxy via CREATE2 pointing to implementation (NO init data for determinism)
            bytes memory proxyCreationCode = abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(implementation, "") // Empty init data - we'll initialize separately
            );
            bytes32 proxySalt = BAO_DEPLOYER_SALT;

            /// @solidity memory-safe-assembly
            assembly {
                let n := mload(proxyCreationCode)
                mstore(proxyCreationCode, proxySalt)
                if iszero(call(gas(), factory, 0, proxyCreationCode, add(n, 0x20), 0x00, 0x20)) {
                    returndatacopy(proxyCreationCode, 0x00, returndatasize())
                    revert(proxyCreationCode, returndatasize())
                }
                mstore(proxyCreationCode, n)
                deployed := shr(96, mload(0x00))
            }

            require(deployed == _getBaoDeployerAddress(), "BaoDeployer proxy deployed to unexpected address");
            require(deployed.code.length > 0, "BaoDeployer proxy has no code");

            // Step 3: Initialize the proxy separately (now address is deterministic regardless of init params)
            BaoDeployer(deployed).initialize(owner, initialDeployers);
        }

        return deployed;
    }

    // ============================================================================
    // Constructor
    // ============================================================================

    /// @notice Initialize deployment with deployer context
    /// @param deployerContext Address to use for CREATE3 determinism.
    ///        Pass address(0) in tests to use address(this).
    ///        Pass predicted harness address in production.
    constructor(address deployerContext) {
        DEPLOYER_CONTEXT = deployerContext == address(0) ? address(this) : deployerContext;
    }

    // ============================================================================
    // Errors
    // ============================================================================

    error ImplementationKeyRequired();

    error LibraryDeploymentFailed(string key);
    error OwnershipTransferFailed(address proxy);
    error OwnerQueryFailed(address proxy);
    error UnexpectedProxyOwner(address proxy, address owner);
    error FactoryDeploymentFailed(string reason);

    // ============================================================================
    // Factory Abstraction
    // ============================================================================

    /// @notice Get the deployer address for CREATE3 operations
    /// @dev Returns BaoDeployer address - same on all chains (deployed via Nick's Factory)
    ///      This is used for both prediction and deployment
    /// @return deployer BaoDeployer contract address
    function _getCreate3Deployer() internal pure virtual returns (address deployer) {
        return _getBaoDeployerAddress();
    }

    /// @notice Deploy contract via CREATE3 using BaoDeployer
    /// @dev CREATE3 provides bytecode-independent deterministic addresses
    ///      Deployment is done by BaoDeployer (same address on all chains)
    /// @param creationCode The contract creation bytecode
    /// @param salt The salt for deterministic address generation
    /// @return deployed The address of the deployed contract
    function _deployViaCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        address baoDeployer = _getBaoDeployerAddress();

        // Ensure BaoDeployer exists
        if (!_baoDeployerExists()) {
            revert FactoryDeploymentFailed("BaoDeployer not deployed - call _ensureBaoDeployer() first");
        }

        // Call BaoDeployer to deploy via CREATE3
        deployed = BaoDeployer(baoDeployer).deployDeterministic(creationCode, salt);
    }

    /// @notice Deploy via CREATE3 with ETH value
    /// @dev Internal helper that calls BaoDeployer's value-enabled deployDeterministic
    /// @param value Amount of ETH to send to the deployed contract's constructor
    /// @param creationCode Contract creation bytecode
    /// @param salt CREATE3 salt for deterministic address
    /// @return deployed Address of the deployed contract
    function _deployViaCreate3WithValue(
        uint256 value,
        bytes memory creationCode,
        bytes32 salt
    ) internal returns (address deployed) {
        address baoDeployer = _getBaoDeployerAddress();

        // Ensure BaoDeployer exists
        if (!_baoDeployerExists()) {
            revert FactoryDeploymentFailed("BaoDeployer not deployed - call _ensureBaoDeployer() first");
        }

        // Call BaoDeployer to deploy via CREATE3 with value
        deployed = BaoDeployer(baoDeployer).deployDeterministic{value: value}(value, creationCode, salt);
    }

    // ============================================================================
    // Deployment Lifecycle
    // ============================================================================

    /// @notice Start a fresh deployment session
    /// @param owner Owner address for deployed contracts
    /// @param network Network name for metadata
    /// @param version Version string for metadata
    /// @param systemSaltString System salt for deterministic addresses
    function start(
        address owner,
        string memory network,
        string memory version,
        string memory systemSaltString
    ) public virtual {
        _initializeMetadata(owner, network, version, systemSaltString);
        _stub = new UUPSProxyDeployStub();
        _saveToRegistry();
    }

    /// @notice Resume deployment from JSON file
    /// @param network Network name (for subdirectory in production)
    /// @param systemSaltString System salt to derive filepath
    function resume(string memory network, string memory systemSaltString) public virtual {
        string memory filepath;
        if (_useNetworkSubdir()) {
            filepath = string.concat(_getBaseDirPrefix(), "deployments/", network, "/", systemSaltString, ".json");
        } else {
            filepath = string.concat(_getBaseDirPrefix(), "deployments/", systemSaltString, ".json");
        }
        loadFromJson(filepath);
        _stub = new UUPSProxyDeployStub();
    }

    /// @notice Resume deployment from custom file path (internal - for tests)
    /// @param filepath Custom path to JSON file
    function _resumeFrom(string memory filepath) internal virtual {
        loadFromJson(filepath);
        _stub = new UUPSProxyDeployStub();
    }

    /// @notice Resume deployment from JSON string (internal - for tests)
    /// @param json JSON string to parse
    function _resumeFromJson(string memory json) internal virtual {
        fromJson(json);
        _stub = new UUPSProxyDeployStub();
    }

    /// @notice Finish deployment session and finalize ownership
    /// @dev Transfers ownership to metadata.owner for all proxies currently owned by this harness
    /// @dev Records run in audit trail and updates finishTimestamp timestamp
    /// @return transferred Number of proxies whose ownership was transferred
    function finish() public virtual returns (uint256 transferred) {
        address owner = _metadata.owner;
        string[] memory allKeys = _keys;
        uint256 length = allKeys.length;

        for (uint256 i; i < length; i++) {
            string memory key = allKeys[i];

            if (_eq(_entryType[key], "proxy")) {
                if (_resumedProxies[key]) {
                    continue;
                }

                address proxy = _proxies[key].info.addr;

                // Check if proxy supports owner() method (BaoOwnable pattern)
                (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
                if (!success || data.length != 32) {
                    // Contract doesn't support BaoOwnable, skip
                    continue;
                }

                address currentOwner = abi.decode(data, (address));

                // Only transfer if current owner is this harness (temporary owner from stub pattern)
                if (currentOwner == address(this)) {
                    IBaoOwnable(proxy).transferOwnership(owner);
                    ++transferred;
                }
            }
        }

        // Mark current run as finished
        require(_runs.length > 0, "No run to finish");
        require(!_runs[_runs.length - 1].finished, "Run already finished");

        _runs[_runs.length - 1].finishTimestamp = block.timestamp;
        _runs[_runs.length - 1].finishBlock = block.number;
        _runs[_runs.length - 1].finished = true;

        // Update metadata timestamps from last run
        _metadata.finishTimestamp = block.timestamp;
        _metadata.finishBlock = block.number;

        _saveToRegistry();
        return transferred;
    }

    // ============================================================================
    // Exposed views
    // ============================================================================

    function getSystemSaltString() public view returns (string memory) {
        return _metadata.systemSaltString;
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
        bytes memory proxySaltBytes = abi.encodePacked(_metadata.systemSaltString, "/", proxyKey, "/UUPS/proxy");
        bytes32 salt = EfficientHashLib.hash(proxySaltBytes);
        address deployer = _getCreate3Deployer();
        proxy = CREATE3.predictDeterministicAddress(salt, deployer);
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
    ) external virtual returns (address) {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        if (_exists[proxyKey]) {
            revert ContractAlreadyExists(proxyKey);
        }
        address implementation = _get(implementationKey);
        if (!_exists[implementationKey] || !_eq(_entryType[implementationKey], "implementation")) {
            revert ImplementationKeyRequired();
        }

        // Compute salt
        bytes memory proxySaltBytes = abi.encodePacked(_metadata.systemSaltString, "/", proxyKey, "/UUPS/proxy");
        bytes32 salt = EfficientHashLib.hash(proxySaltBytes);
        string memory saltString = proxyKey;

        // Step 1: Deploy proxy via factory pointing to stub (no initialization yet)
        bytes memory proxyCreationCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(_stub), bytes(""))
        );
        address proxy = _deployViaCreate3(proxyCreationCode, salt);

        // Step 2: Upgrade to real implementation with atomic initialization
        // msg.sender during initialize will be this contract (harness) via stub ownership
        IUUPSUpgradeableProxy(proxy).upgradeToAndCall(implementation, implementationInitData);

        _registerProxy(
            proxyKey,
            proxy,
            implementationKey,
            salt,
            saltString,
            "UUPS",
            _metadata.deployer,
            _runs[_runs.length - 1].deployer
        );
        _saveToRegistry();

        emit ContractDeployed(proxyKey, proxy, "UUPS proxy");
        return proxy;
    }

    function upgradeProxy(
        string memory proxyKey,
        string memory newImplementationKey,
        bytes memory initData
    ) external virtual {
        if (bytes(proxyKey).length == 0 || bytes(newImplementationKey).length == 0) {
            revert KeyRequired();
        }
        address proxy = _getProxy(proxyKey);
        address newImplementation = _getImplementation(newImplementationKey);

        if (initData.length == 0) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
        } else {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(newImplementation, initData);
        }

        // Update registry to reflect the new implementation
        _updateProxyImplementation(proxyKey, newImplementationKey);
        _saveToRegistry();

        emit ContractUpdated(proxyKey, proxy, proxy);
    }

    // ============================================================================
    // Registration Helpers
    // ============================================================================

    function _registerStandardContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        string memory category,
        address deployer
    ) internal virtual override {
        super._registerStandardContract(key, addr, contractType, contractPath, category, deployer);
        _saveToRegistry();
    }

    function useExisting(string memory key, address addr) public virtual {
        _requireActiveRun();
        _requireValidAddress(key, addr);
        _registerStandardContract(key, addr, "ExistingContract", "blockchain", "existing", address(0));
    }

    function _registerImplementationEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal {
        _requireActiveRun();
        _requireValidAddress(key, addr);
        _registerImplementation(key, addr, contractType, contractPath, _runs[_runs.length - 1].deployer);
        _saveToRegistry();
        emit ContractDeployed(key, addr, "implementation");
    }

    function _registerLibraryEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal {
        _requireActiveRun();
        _requireValidAddress(key, addr);
        _registerLibrary(key, addr, contractType, contractPath, _runs[_runs.length - 1].deployer);
        _saveToRegistry();
        emit ContractDeployed(key, addr, "library");
    }

    function _deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) internal {
        if (_exists[key]) {
            revert LibraryAlreadyExists(key);
        }
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        if (addr == address(0)) {
            revert LibraryDeploymentFailed(key);
        }
        _registerLibraryEntry(key, addr, contractType, contractPath);
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

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

    // ============================================================================
    // Parameter Setters with Auto-save
    // ============================================================================

    function _setString(string memory key, string memory value) internal virtual override {
        super._setString(key, value);
        _saveToRegistry();
    }

    function _setUint(string memory key, uint256 value) internal virtual override {
        super._setUint(key, value);
        _saveToRegistry();
    }

    function _setInt(string memory key, int256 value) internal virtual override {
        super._setInt(key, value);
        _saveToRegistry();
    }

    function _setBool(string memory key, bool value) internal virtual override {
        super._setBool(key, value);
        _saveToRegistry();
    }
}
