// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {DeploymentBase, WellKnownAddress} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

interface IUUPSProxyUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IBaoOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Base contract providing CREATE3 proxy deployment via BaoFactory.
/// @dev Deployment calls execute in the derived contract's context (important for permissions).
/// @dev Includes DeploymentOwnership pattern - tracks deployed contracts and transfers ownership at end.
/// @dev Inherits DeploymentBase to get baoFactory(), owner(), saltPrefix() from context.
abstract contract FactoryDeployer is DeploymentBase {
    /// @dev Lazily deployed stub - must be deployed within broadcast context so msg.sender is correct.
    UUPSProxyDeployStub private _proxyDeployStub;

    // ========== DEPLOYMENT OWNERSHIP PATTERN ==========
    // Contracts are deployed with deployer as owner, then transferred at end.
    // initialize(owner()) sets pending owner; transferOwnership(owner()) confirms it.

    struct PendingOwnership {
        address deployed;
        string salt;
    }

    /// @dev List of deployed contracts needing ownership transfer.
    PendingOwnership[] private _pendingOwnershipTransfers;

    /// @notice Get or deploy the proxy stub. Must be called within broadcast context.
    /// @dev Deploys on first call, returns cached address on subsequent calls.
    function _getOrDeployStub() internal returns (UUPSProxyDeployStub) {
        if (address(_proxyDeployStub) == address(0)) {
            _proxyDeployStub = new UUPSProxyDeployStub();
            console.log("      UUPSProxyDeployStub: %s", address(_proxyDeployStub));
        }
        return _proxyDeployStub;
    }

    /// @notice Register a deployed contract for later ownership transfer.
    /// @dev Call this after deploying any contract that needs ownership transferred.
    function _registerForOwnershipTransfer(address deployed, string memory salt) internal {
        _pendingOwnershipTransfers.push(PendingOwnership(deployed, salt));
    }

    /// @notice Transfer ownership of all registered contracts to final owner.
    /// @dev No parameter needed - pending owner was set to owner() during initialize().
    function _transferAllOwnerships() internal {
        address pendingOwner = owner();
        string memory ownerLabel = _addressLabel(pendingOwner);
        for (uint256 i = 0; i < _pendingOwnershipTransfers.length; i++) {
            PendingOwnership memory pending = _pendingOwnershipTransfers[i];
            console.log("        %s -> %s", pending.salt, ownerLabel);
            IBaoOwnable(pending.deployed).transferOwnership(pendingOwner);
        }
        // Clear the list after transfer
        delete _pendingOwnershipTransfers;
    }

    /// @notice Get count of contracts pending ownership transfer.
    function _pendingOwnershipCount() internal view returns (uint256) {
        return _pendingOwnershipTransfers.length;
    }

    /// @notice Look up a human-readable label for an address.
    /// @dev Uses getWellKnownAddresses() to find a label. Falls back to hex address.
    function _addressLabel(address addr) internal view returns (string memory) {
        WellKnownAddress[] memory known = getWellKnownAddresses();
        for (uint256 i = 0; i < known.length; i++) {
            if (known[i].addr == addr) {
                return known[i].label;
            }
        }
        return Strings.toHexString(addr);
    }

    // ========== SALT STRING CONSTRUCTION ==========
    // All "::" salt construction happens here - nowhere else in the codebase.
    // Parameters are generic (part1, part2, part3) as they vary by use case.

    /// @notice Construct salt string for a single-part key (e.g., "ETH::pegged")
    function _saltString(string memory a) internal view returns (string memory) {
        return string.concat(saltPrefix(), "::", a);
    }

    /// @notice Construct salt string for two-part key (e.g., "ETH::fxUSD", "minter")
    function _saltString(string memory a, string memory b) internal view returns (string memory) {
        return string.concat(saltPrefix(), "::", a, "::", b);
    }

    /// @notice Construct salt string for three-part key (e.g., "ETH", "fxUSD", "minter")
    function _saltString(string memory a, string memory b, string memory c) internal view returns (string memory) {
        return string.concat(saltPrefix(), "::", a, "::", b, "::", c);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict address for a single-part key (e.g., "ETH::pegged")
    function _predictAddress(string memory a) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_saltString(a)));
        return IBaoFactory(baoFactory()).predictAddress(salt);
    }

    /// @notice Predict address for two-part key (e.g., "ETH::fxUSD", "minter")
    function _predictAddress(string memory a, string memory b) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_saltString(a, b)));
        return IBaoFactory(baoFactory()).predictAddress(salt);
    }

    /// @notice Predict address for three-part key (e.g., "ETH", "fxUSD", "minter")
    function _predictAddress(string memory a, string memory b, string memory c) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_saltString(a, b, c)));
        return IBaoFactory(baoFactory()).predictAddress(salt);
    }

    // ========== DEPLOY AND RECORD ==========

    /// @notice Deploy a proxy and record both implementation and proxy in state.
    /// @dev This is the main entry point for all proxy deployments - ensures recording cannot be forgotten.
    /// @param stateData Deployment state to record into.
    /// @param proxyId The proxy identifier (e.g., "ETH::fxUSD::minter").
    /// @param implementation The implementation contract address.
    /// @param contractSource Source file path for the implementation (e.g., "@harbor/minter/Minter_v1.sol").
    /// @param contractType Contract type name (e.g., "Minter_v1").
    /// @param initData Initialization calldata for the proxy.
    /// @return proxy The deployed proxy address.
    function _deployProxyAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        string memory contractSource,
        string memory contractType,
        bytes memory initData
    ) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix(), "::", proxyId));
        proxy = deployProxy(baoFactory(), salt, implementation, initData);

        // Record implementation
        DeploymentState.recordImplementation(
            stateData,
            DeploymentTypes.ImplementationRecord({
                proxy: proxyId,
                contractSource: contractSource,
                contractType: contractType,
                implementation: implementation,
                deploymentTime: uint64(block.timestamp)
            })
        );

        // Record proxy
        DeploymentState.recordProxy(
            stateData,
            DeploymentTypes.ProxyRecord({
                id: proxyId,
                proxy: proxy,
                implementation: implementation,
                salt: saltPrefix(),
                deploymentTime: uint64(block.timestamp)
            })
        );

        // Register for ownership transfer
        _registerForOwnershipTransfer(proxy, _saltString(proxyId));

        console.log("        Proxy: %s", proxy);
    }

    /// @notice Deploy a proxy via CREATE3 using BaoFactory.
    /// @dev Private - all deployments must go through _deployProxyAndRecord() to ensure recording.
    /// @param factory BaoFactory address.
    /// @param salt CREATE3 salt.
    /// @param implementation Implementation contract address.
    /// @param initData Initialization calldata for the proxy.
    /// @return proxy The deployed proxy address.
    function deployProxy(
        address factory,
        bytes32 salt,
        address implementation,
        bytes memory initData
    ) private returns (address proxy) {
        IBaoFactory baoFactoryContract = IBaoFactory(factory);

        // Predict proxy address
        address predictedProxy = baoFactoryContract.predictAddress(salt);

        // Get or deploy stub (must happen within broadcast context)
        UUPSProxyDeployStub stub = _getOrDeployStub();

        // Step 1: deploy proxy pointing at stub
        proxy = baoFactoryContract.deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt
        );
        require(proxy == predictedProxy, "Proxy address mismatch");

        // Step 2: upgrade to real implementation and initialize (msg.sender = this contract, owner per stub)
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(implementation, initData);
        return proxy;
    }
}
