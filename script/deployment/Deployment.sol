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
 *      - Deterministic proxy deployment via CREATE3, using a shared UUPS stub
 *      - Library deployment via CREATE
 *      - Existing contract registration helpers
 *      - Thin wrappers around registry storage helpers
 *      - Designed for specialization (e.g. Harbor overrides deployProxy)
 */
abstract contract Deployment is DeploymentJson {
    // ============================================================================
    // Errors
    // ============================================================================

    error ImplementationRequired();
    error SaltRequired();
    error LibraryDeploymentFailed(string key);
    error OwnershipTransferFailed(address proxy);
    error OwnerQueryFailed(address proxy);
    error UnexpectedProxyOwner(address proxy, address owner);

    address private _stub;

    // ============================================================================
    // Bootstrap / Stub configuration
    // ============================================================================

    /**
     * @dev Ensure the stored stub is configured and the current contract is the deployer.
     */
    function _syncStubFromMetadata() internal {
        address stubAddress = _metadata.stubAddress;
        if (stubAddress == address(0)) {
            revert InvalidStub(stubAddress);
        }

        address deployerAddress = _queryStubDeployer(stubAddress);
        if (deployerAddress != address(this)) {
            revert InvalidStubDeployer(stubAddress, deployerAddress);
        }

        _stub = stubAddress;
        if (bytes(_metadata.stubImplementation).length == 0) {
            _metadata.stubImplementation = "UUPSProxyDeployStub";
        }
    }

    function _queryStubDeployer(address stubAddress) private view returns (address deployer) {
        try UUPSProxyDeployStub(stubAddress).deployer() returns (address value) {
            deployer = value;
        } catch {
            revert InvalidStub(stubAddress);
        }
    }

    /**
     * @dev Configure the stub for the current session.
     */
    function _configureDeployStub(address stubAddress, string memory stubImplementation) internal {
        if (stubAddress == address(0)) {
            revert InvalidStub(stubAddress);
        }

        address deployerAddress = _queryStubDeployer(stubAddress);
        if (deployerAddress != address(this)) {
            revert InvalidStubDeployer(stubAddress, deployerAddress);
        }

        _stub = stubAddress;
        _metadata.stubAddress = stubAddress;

        if (bytes(stubImplementation).length == 0) {
            _metadata.stubImplementation = "UUPSProxyDeployStub";
        } else {
            _metadata.stubImplementation = stubImplementation;
        }
    }

    // ============================================================================
    // Exposed views
    // ============================================================================

    function makeSalt(string memory key) internal view returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(_metadata.systemSaltString, key, "UUPS"));
    }

    function getSystemSaltString() public view returns (string memory) {
        return _metadata.systemSaltString;
    }

    function getDeployStub() public view returns (address) {
        return _stub;
    }

    // ============================================================================
    // Lifecycle overrides
    // ============================================================================

    function startDeployment(
        address deployer,
        string memory network,
        string memory version,
        string memory systemSaltString
    ) public override {
        if (_stub == address(0)) {
            revert InvalidStub(_stub);
        }

        string memory stubImplementation = _metadata.stubImplementation;

        super.startDeployment(deployer, network, version, systemSaltString);

        _metadata.stubAddress = _stub;
        if (bytes(stubImplementation).length == 0) {
            stubImplementation = "UUPSProxyDeployStub";
        }
        _metadata.stubImplementation = stubImplementation;
    }

    function resumeDeployment(address deployer) public virtual override {
        super.resumeDeployment(deployer);
        _syncStubFromMetadata();
    }

    function fromJson(string memory json) public virtual override {
        super.fromJson(json);
        _syncStubFromMetadata();
    }

    // ============================================================================
    // Proxy Deployment / Upgrades
    // ============================================================================

    function deployProxy(
        string memory key,
        address implementation,
        bytes memory initData
    ) public virtual returns (address proxy) {
        _requireActive();
        if (_exists[key]) {
            revert ContractAlreadyExists(key);
        }
        if (implementation == address(0)) revert ImplementationRequired();
        if (bytes(key).length == 0) revert SaltRequired();

        if (_stub == address(0)) {
            revert InvalidStub(_stub);
        }

        bytes memory creationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_stub, ""));

        bytes32 salt = makeSalt(key);
        proxy = CREATE3.deployDeterministic(creationCode, salt);

        _registerProxy(key, proxy, "", salt, key, "UUPS");

        if (initData.length == 0) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(implementation);
        } else {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(implementation, initData);
        }

        emit ContractDeployed(key, proxy, "UUPS proxy");
        return proxy;
    }

    function upgradeProxy(
        string memory key,
        address newImplementation,
        bytes memory initData
    ) public virtual returns (address proxy) {
        _requireActive();
        if (!_exists[key] || !_eq(_entryType[key], "proxy")) {
            revert ContractNotFound(key);
        }
        if (newImplementation == address(0)) revert ImplementationRequired();

        proxy = _proxies[key].info.addr;

        if (initData.length == 0) {
            IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
        } else {
            IUUPSUpgradeableProxy(proxy).upgradeToAndCall(newImplementation, initData);
        }

        emit ContractUpdated(key, proxy, proxy);
    }

    function predictProxyAddress(string memory key) public view returns (address) {
        if (bytes(key).length == 0) revert SaltRequired();
        return CREATE3.predictDeterministicAddress(makeSalt(key), address(this));
    }

    // ============================================================================
    // Registration Helpers
    // ============================================================================

    function useExisting(string memory key, address addr) public virtual returns (address) {
        _requireActive();
        return _registerContractEntry(key, addr, "ExistingContract", "", "existing");
    }

    function _registerContractEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        string memory category
    ) internal returns (address) {
        _requireValidAddress(key, addr);
        _registerContract(key, addr, contractType, contractPath, category);
        emit ContractDeployed(key, addr, category);
        return addr;
    }

    function _registerImplementationEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal returns (address) {
        _requireValidAddress(key, addr);
        _registerImplementation(key, addr, contractType, contractPath);
        emit ContractDeployed(key, addr, "implementation");
        return addr;
    }

    function _registerLibraryEntry(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) internal returns (address) {
        _requireValidLibrary(key, addr);
        _registerLibrary(key, addr, contractType, contractPath);
        emit ContractDeployed(key, addr, "library");
        return addr;
    }

    function _deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) internal returns (address) {
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
        return addr;
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
                address proxy = _proxies[key].info.addr;
                address currentOwner;
                try IBaoOwnable(proxy).owner() returns (address owner) {
                    currentOwner = owner;
                } catch {
                    revert OwnerQueryFailed(proxy);
                }

                if (currentOwner != address(this)) {
                    revert UnexpectedProxyOwner(proxy, currentOwner);
                }

                try IBaoOwnable(proxy).transferOwnership(newOwner) {
                    ++transferred;
                } catch {
                    revert OwnershipTransferFailed(proxy);
                }
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
