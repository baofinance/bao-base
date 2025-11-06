// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

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
abstract contract Deployment is DeploymentRegistry {
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
    function _getCreate3Deployer() internal view virtual returns (address deployer) {
        deployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (deployer == address(0)) {
            revert FactoryDeploymentFailed("BaoDeployer owner not configured");
        }
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

        require(DeploymentInfrastructure.predictBaoDeployerAddress().code.length > 0, "need to deploy the BaoDeployer");

        // if the deployer is not deployed then we cannot start
        _stub = new UUPSProxyDeployStub();
    }

    function deployBaoDeployer() public {
        DeploymentInfrastructure.deployBaoDeployer();
    }

    /// @notice Resume deployment from JSON file
    /// @param network Network name (for subdirectory in production)
    /// @param systemSaltString System salt to derive filepath
    function resume(string memory network, string memory systemSaltString) public virtual {
        _loadRegistry(_filepath(network, systemSaltString));
        _stub = new UUPSProxyDeployStub();
    }

    /// @notice Resume deployment from custom file path (internal - for tests)
    /// @param filepath Custom path to JSON file
    function _resumeFrom(string memory filepath) internal virtual {
        _loadRegistry(filepath);
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

        _saveRegistry();
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
    function deployProxy(
        uint256 value,
        string memory proxyKey,
        string memory implementationKey,
        bytes memory implementationInitData
    ) external virtual returns (address proxy) {
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

    function _deployContract(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory contractType,
        string memory contractPath
    ) internal virtual returns (address addr) {
        _requireActiveRun();
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_exists[key]) {
            revert ContractAlreadyExists(key);
        }

        // Compute salt
        bytes memory saltBytes = abi.encodePacked(_metadata.systemSaltString, "/", key, "/contract");
        bytes32 salt = EfficientHashLib.hash(saltBytes);
        // string memory saltString = key;

        // commit-reveal via to avoid front-running the deployment which could steal our address
        BaoDeployer deployer = BaoDeployer(DeploymentInfrastructure.predictBaoDeployerAddress());
        bytes32 commitment = DeploymentInfrastructure.commitment(address(this), value, salt, keccak256(initCode));

        deployer.commit(commitment);
        addr = deployer.reveal{value: value}(initCode, salt, value);

        // TODO: register predeicted address contract
        _registerStandardContract(
            key,
            addr,
            "CREATE3 contract",
            contractType,
            contractPath,
            _runs[_runs.length - 1].deployer
        );

        emit ContractDeployed(key, addr, "CREATE3 contract");
        return addr;
    }

    function _deployProxy(
        uint256 value,
        string memory proxyKey,
        string memory implementationKey,
        bytes memory implementationInitData
    ) internal virtual returns (address proxy) {
        _requireActiveRun();
        if (bytes(proxyKey).length == 0) {
            revert KeyRequired();
        }
        if (_exists[proxyKey]) {
            revert ContractAlreadyExists(proxyKey);
        }
        address implementation = get(implementationKey);
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

        // commit-reveal via to avoid front-running the deployment which could steal our address
        {
            BaoDeployer deployer = BaoDeployer(DeploymentInfrastructure.predictBaoDeployerAddress());
            deployer.commit(
                DeploymentInfrastructure.commitment(
                    address(this),
                    value,
                    salt,
                    EfficientHashLib.hash(proxyCreationCode)
                )
            );
            proxy = deployer.reveal{value: value}(proxyCreationCode, salt, value);
        }

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

        emit ContractUpdated(proxyKey, proxy, proxy);
    }

    function useExisting(string memory key, address addr) public virtual {
        _registerStandardContract(key, addr, "ExistingContract", "blockchain", "existing", address(0));
    }

    function registerImplementation(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) public {
        _requireActiveRun();
        _requireValidAddress(key, addr);
        super._registerImplementation(key, addr, contractType, contractPath, _runs[_runs.length - 1].deployer);
        emit ContractDeployed(key, addr, "implementation");
    }

    function deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) public {
        _requireActiveRun();

        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        if (addr == address(0)) {
            revert LibraryDeploymentFailed(key);
        }

        _registerLibrary(key, addr, contractType, contractPath, _runs[_runs.length - 1].deployer);
        emit ContractDeployed(key, addr, "library");
    }
}
