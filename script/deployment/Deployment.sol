// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {Stem_v1} from "@bao/Stem_v1.sol";

import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";

interface IStemUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
}

/**
 * @title Deployment
 * @notice Deployment operations layer built on top of DeploymentRegistry
 * @dev Responsibilities:
 *      - Deterministic proxy deployment via CREATE3, and using Stem_v1 as initial implementation
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

    address private _stem;

    constructor() {
        _stem = address(new Stem_v1(address(this), 0));
    }

    /**
     * @notice Generate deterministic salt from registry key
     * @param key The registry key for the deployment
     * @return The deterministic salt for CREATE3
     */
    function makeSalt(string memory key) internal view returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(_metadata.systemSaltString, key, "UUPS"));
    }

    /**
     * @notice Get the system salt string used for deterministic deployments
     * @return The system salt string
     */
    function getSystemSaltString() public view returns (string memory) {
        return _metadata.systemSaltString;
    }

    /**
     * @notice Get the stem contract address used for proxy deployments
     * @return The stem contract address
     */
    function getStemContract() public view returns (address) {
        return _stem;
    }

    /**
     * @notice Start a deployment session (overrides parent to set stem contract)
     */
    function startDeployment(
        address deployer,
        string memory network,
        string memory version,
        string memory systemSaltString
    ) public override {
        super.startDeployment(deployer, network, version, systemSaltString);
        _metadata.stemContract = _stem;
    }

    // ============================================================================
    // Proxy Deployment
    // ============================================================================

    /**
     * @notice Deploy a deterministic UUPS proxy using CREATE3
     * @param key Registry key to register the deployed proxy under
     * @param implementation Address of the implementation contract
     * @param initData Calldata executed against implementation during proxy construction
     * @return proxy Address of the deployed proxy
     */
    function deployProxy(
        string memory key,
        address implementation,
        bytes memory initData
    ) public virtual returns (address proxy) {
        if (_exists[key]) {
            revert ContractAlreadyExists(key);
        }
        if (implementation == address(0)) revert ImplementationRequired();
        if (bytes(key).length == 0) revert SaltRequired();

        string memory proxyType = "UUPS";
        bytes memory creationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_stem, ""));

        bytes32 salt = makeSalt(key);
        proxy = CREATE3.deployDeterministic(creationCode, salt);

        _registerProxy(key, proxy, "", salt, key, proxyType);

        // Upgrade Stem → actual implementation with initialization
        // Note: This external call happens AFTER state changes to prevent reentrancy
        if (initData.length == 0) {
            IStemUUPS(proxy).upgradeTo(implementation);
        } else {
            IStemUUPS(proxy).upgradeToAndCall(implementation, initData);
        }

        emit ContractDeployed(key, proxy, "UUPS proxy");

        return proxy;
    }

    /**
     * @notice Predict the proxy address for a given key
     * @param key Registry key for the deployment
     * @return Predicted address for the deployment
     */
    function predictProxyAddress(string memory key) public view returns (address) {
        if (bytes(key).length == 0) revert SaltRequired();
        return CREATE3.predictDeterministicAddress(makeSalt(key), address(this));
    }

    // ============================================================================
    // Registration Helpers
    // ============================================================================

    /**
     * @notice Register an existing deployment under a key
     * @param key Registry key
     * @param addr Existing contract address (must be non-zero)
     * @return Address that was registered (for chaining)
     */
    function useExisting(string memory key, address addr) public virtual returns (address) {
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

    // ============================================================================
    // Library Deployment
    // ============================================================================

    /**
     * @notice Deploy a library via CREATE (non-deterministic)
     * @param key Registry key
     * @param bytecode Raw creation bytecode for the library
     * @param contractType Logical type metadata
     * @param contractPath Source path metadata
     * @return Address of deployed library
     */
    function _deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) internal returns (address) {
        if (_exists[key]) {
            revert LibraryAlreadyExists(key);
        }
        address addr;
        // solhint-disable-next-line no-inline-assembly
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

    /**
     * @notice Finalize ownership for all Stem proxies controlled by this deployment
     * @param newOwner Address that should receive ownership
     * @return transferred Number of proxies that transferred ownership
     */
    function finalizeOwnership(address newOwner) public returns (uint256 transferred) {
        if (newOwner == address(0)) {
            revert InvalidAddress("finalizeOwnership");
        }

        string[] memory allKeys = _keys;
        uint256 length = allKeys.length;

        for (uint256 i; i < length; i++) {
            string memory key = allKeys[i];

            if (_eq(_entryType[key], "proxy")) {
                address proxy = _proxies[key].info.addr;

                IBaoOwnable(proxy).transferOwnership(newOwner);
                ++transferred;
            }
        }
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
