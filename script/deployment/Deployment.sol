// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";

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
    // Constants
    // ============================================================================

    /// @notice Nick's Factory address for deterministic CREATE2 deployments
    /// @dev Available on 100+ chains at this address
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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
    error KeyRequired();

    error LibraryDeploymentFailed(string key);
    error OwnershipTransferFailed(address proxy);
    error OwnerQueryFailed(address proxy);
    error UnexpectedProxyOwner(address proxy, address owner);

    // TODO: add start & resume Deployment
    // TODO:
    // ============================================================================
    // Exposed views
    // ============================================================================

    function getSystemSaltString() public view returns (string memory) {
        return _metadata.systemSaltString;
    }

    // ============================================================================
    // Proxy Deployment / Upgrades
    // ============================================================================

    enum Create3Mode {
        Predict,
        Deploy
    }

    /// @notice Internal proxy deployment logic with CREATE3
    /// @dev Uses DEPLOYER_CONTEXT for address calculations to ensure cross-chain determinism
    /// @param mode Predict or Deploy
    /// @param proxyKey Key for the proxy deployment
    /// @return proxy Proxy address (deployed or predicted)
    /// @return salt Salt used for CREATE3
    /// @return saltString Human-readable salt string
    function _doProxy(
        Create3Mode mode,
        string memory proxyKey
    ) internal returns (address proxy, bytes32 salt, string memory saltString) {
        // crystalise the salts - need different salts for stub and proxy
        bytes memory stubSaltBytes = abi.encodePacked(_metadata.systemSaltString, "/", proxyKey, "/UUPS/stub");
        bytes32 stubSalt = EfficientHashLib.hash(stubSaltBytes);

        bytes memory proxySaltBytes = abi.encodePacked(_metadata.systemSaltString, "/", proxyKey, "/UUPS/proxy");
        salt = EfficientHashLib.hash(proxySaltBytes);
        saltString = proxyKey;

        // deploy the stub at deterministic address using DEPLOYER_CONTEXT
        address stub;
        if (mode == Create3Mode.Deploy) {
            stub = CREATE3.deployDeterministic(type(UUPSProxyDeployStub).creationCode, stubSalt);
        } else {
            stub = CREATE3.predictDeterministicAddress(stubSalt, DEPLOYER_CONTEXT);
        }
        /// deploy the proxy at deterministic address using DEPLOYER_CONTEXT
        bytes memory proxyCreationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(stub, bytes("")));
        if (mode == Create3Mode.Deploy) {
            proxy = CREATE3.deployDeterministic(proxyCreationCode, salt);
        } else {
            proxy = CREATE3.predictDeterministicAddress(salt, DEPLOYER_CONTEXT);
        }
    }

    /// @notice Predict proxy address without deploying
    /// @param proxyKey Key for the proxy deployment
    /// @return proxy Predicted proxy address
    /// @return salt Salt that will be used for CREATE3
    /// @return saltString Human-readable salt string
    function _predictProxy(
        string memory proxyKey
    ) internal view returns (address proxy, bytes32 salt, string memory saltString) {
        // crystalise the proxy salt (same as in _doProxy)
        bytes memory proxySaltBytes = abi.encodePacked(_metadata.systemSaltString, "/", proxyKey, "/UUPS/proxy");
        salt = EfficientHashLib.hash(proxySaltBytes);
        saltString = proxyKey;

        // predict proxy address using DEPLOYER_CONTEXT
        proxy = CREATE3.predictDeterministicAddress(salt, DEPLOYER_CONTEXT);
    }

    /// @dev this only works with BaoOwnable derived implementations
    function deployProxy(
        string memory proxyKey,
        string memory implementationKey,
        bytes memory implementationInitData
    ) external virtual returns (address) {
        _requireActive();
        if (_exists[proxyKey]) {
            revert ContractAlreadyExists(proxyKey);
        }
        address implementation = _get(implementationKey);
        if (!_exists[implementationKey] || !_eq(_entryType[implementationKey], "implementation")) {
            revert ImplementationKeyRequired();
        }

        // deploy the proxy (+ stub)
        (address proxy, bytes32 salt, string memory saltString) = _doProxy(Create3Mode.Deploy, proxyKey);

        // install the implementation
        IUUPSUpgradeableProxy(proxy).upgradeToAndCall(implementation, implementationInitData);

        _registerProxy(proxyKey, proxy, implementationKey, salt, saltString, "UUPS");

        emit ContractDeployed(proxyKey, proxy, "UUPS proxy");
        return proxy;
    }

    // TODO: rather than an implementation address, it should take an implementation key
    function upgradeProxy(
        string memory key,
        string memory /* newImplementationKey */,
        bytes memory initData
    ) external virtual {
        _requireActive();
        address proxy = _getProxy(key);
        address newImplementation = _getImplementation(key);

        if (initData.length == 0) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
        } else {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(newImplementation, initData);
        }

        emit ContractUpdated(key, proxy, proxy);
    }

    function predictProxyAddress(string memory proxyKey) public view returns (address proxy) {
        (proxy, , ) = _predictProxy(proxyKey);
    }

    // ============================================================================
    // Registration Helpers
    // ============================================================================

    function useExisting(string memory key, address addr) public virtual {
        _requireActive();
        _requireValidAddress(key, addr);
        _registerContract(key, addr, "ExistingContract", "blockchain", "existing");
    }

    function _registerImplementationEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal {
        _requireValidAddress(key, addr);
        _registerImplementation(key, addr, contractType, contractPath);
        emit ContractDeployed(key, addr, "implementation");
    }

    function _registerLibraryEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal {
        _requireValidLibrary(key, addr);
        _registerLibrary(key, addr, contractType, contractPath);
        emit ContractDeployed(key, addr, "library");
    }

    function _deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) internal {
        _requireActive();
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

    // =========================================================================
    // Ownership Finalization
    // =========================================================================

    function _finalizeOwnership(address newOwner) internal returns (uint256 transferred) {
        _requireActive();
        if (newOwner == address(0)) {
            revert InvalidAddress("finalizeOwnership");
        }

        string[] memory allKeys = _keys;
        uint256 length = allKeys.length;

        for (uint256 i; i < length; i++) {
            string memory key = allKeys[i];

            if (_eq(_entryType[key], "proxy")) {
                if (_resumedProxies[key]) {
                    continue;
                }

                address proxy = _proxies[key].info.addr;
                IBaoOwnable(proxy).transferOwnership(newOwner);
                ++transferred;
            }
        }

        return transferred;
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

    function _requireValidAddress(string memory key, address addr) internal view {
        if (addr == address(0)) {
            revert InvalidAddress(key);
        }
        if (_exists[key]) {
            revert ContractAlreadyExists(key);
        }
    }

    function _requireValidLibrary(string memory key, address addr) internal view {
        if (addr == address(0)) {
            revert InvalidAddress(key);
        }
        if (_exists[key]) {
            revert LibraryAlreadyExists(key);
        }
    }
}
