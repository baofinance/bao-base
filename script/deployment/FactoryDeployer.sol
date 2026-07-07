// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {SaltString} from "@bao-script/deployment/SaltString.sol";

/// @notice Well-known address entry for address-to-label mapping.
struct WellKnownAddress {
    address addr;
    string label;
}

interface IUUPSProxyUpgrade {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IBaoOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Base contract providing CREATE3 proxy deployment via BaoFactory.
/// @dev Deployment calls execute in the derived contract's context (important for permissions).
/// @dev Includes DeploymentOwnership pattern - tracks deployed contracts and transfers ownership at end.
/// @dev Protocol-specific configs inherit this and implement owner(), treasury().
/// @dev All deployment operations are idempotent - safe to re-run.
abstract contract FactoryDeployer {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========== CONSTANTS ==========

    /// @dev Foundry VM cheatcode address.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ========== ERRORS ==========

    /// @notice Predicting an address or deploying before the salt prefix (the CREATE3 namespace) has been set.
    error SaltPrefixNotSet();
    /// @notice `_setSaltPrefix` was given the empty string, which is reserved as the "unset" marker.
    error EmptySaltPrefix();
    /// @notice The salt prefix is write-once; it was already `current` when a set to `attempted` was tried.
    error SaltPrefixAlreadySet(string current, string attempted);

    // ========== CONFIGURATION STATE ==========

    /// @dev Salt prefix for deployment namespacing.
    string private _saltPrefixValue;

    /// @dev Lazily deployed stub - must be deployed within broadcast context so msg.sender is correct.
    UUPSProxyDeployStub private _proxyDeployStub;

    // ========== DEPLOYMENT OWNERSHIP PATTERN ==========
    // Contracts are deployed with deployer as owner, then transferred at end.
    // initialize(owner()) sets pending owner; transferOwnership(owner()) confirms it.

    /// @dev Set of deployed contract addresses needing ownership transfer.
    EnumerableSet.AddressSet private _pendingOwnershipTransfers;

    /// @dev Salt labels for logging (address -> salt string).
    mapping(address => string) private _ownershipTransferSalts;

    // ========== ABSTRACT CONFIGURATION ==========
    // Protocol-specific configs must implement these.

    /// @notice Get the treasury address for the protocol.
    function treasury() public view virtual returns (address);

    /// @notice Get the owner address for deployed contracts.
    function owner() public view virtual returns (address);

    // ========== CONFIGURATION WITH DEFAULTS ==========

    /// @notice Set the deployment salt prefix (the CREATE3 namespace) - must be called once, before any address
    /// prediction or deployment. Write-once: the empty string is the "unset" marker (so it cannot be set as a prefix),
    /// and a second set is rejected rather than silently overwriting an established namespace. The deploy entrypoints
    /// (e.g. deployHarborForPeg) set it from their saltPrefix argument, so a caller passes the namespace to the deploy
    /// rather than establishing it separately - avoiding a standalone temporal dependency before the deploy runs.
    function _setSaltPrefix(string memory saltPrefixString) internal virtual {
        if (bytes(saltPrefixString).length == 0) {
            revert EmptySaltPrefix();
        }
        if (bytes(_saltPrefixValue).length != 0) {
            revert SaltPrefixAlreadySet(_saltPrefixValue, saltPrefixString);
        }
        _saltPrefixValue = saltPrefixString;
    }

    /// @notice Get the current salt prefix for deployment namespacing.
    function saltPrefix() public view virtual returns (string memory) {
        return _saltPrefixValue;
    }

    /// @notice Get the BaoFactory address for CREATE3 deployments.
    /// @dev Override if using a different factory address.
    function baoFactory() public view virtual returns (address) {
        // BaoFactory CREATE2/CREATE3 predicted address (same on all EVM chains)
        return 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458;
    }

    /// @notice Return protocol-level well-known addresses for logging.
    /// @dev Override in protocol configs to add protocol-specific addresses.
    function getWellKnownAddresses() public view virtual returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](3);
        addrs[0] = WellKnownAddress({addr: treasury(), label: "treasury"});
        addrs[1] = WellKnownAddress({addr: owner(), label: "owner"});
        addrs[2] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
    }

    /// @notice Whether to persist deployment state to disk.
    /// @dev Override in tests to disable persistence.
    function _shouldPersistState() internal pure virtual returns (bool) {
        return true;
    }

    /// @notice Resolve the state file path for reading.
    /// @dev Default reads DEPLOY_STATE_FILE_READ env var (set by run-script).
    ///      Override in tests to return a test-specific path.
    function _stateFileRead() internal view virtual returns (string memory) {
        return vm.envString("DEPLOY_STATE_FILE_READ");
    }

    /// @notice Resolve the state file path for writing.
    /// @dev Default reads DEPLOY_STATE_FILE_WRITE env var (set by run-script).
    ///      run-script sets this to a separate file so forge's internal simulation
    ///      pass cannot pollute the file that the broadcast pass reads.
    ///      Override in tests to return a test-specific path.
    function _stateFileWrite() internal view virtual returns (string memory) {
        return vm.envString("DEPLOY_STATE_FILE_WRITE");
    }

    /// @notice Save deployment state to the write file (respects _shouldPersistState).
    function _saveState(DeploymentTypes.State memory stateData) internal virtual {
        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateFileWrite());
        }
    }

    // ========== PROXY STUB MANAGEMENT ==========

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
    /// @dev Idempotent: EnumerableSet ignores duplicates.
    function _registerForOwnershipTransfer(address deployed, string memory salt) internal {
        _pendingOwnershipTransfers.add(deployed);
        _ownershipTransferSalts[deployed] = salt;
    }

    /// @notice Transfer ownership of all registered contracts to final owner.
    /// @dev Idempotent: skips contracts already owned by the target owner.
    function _transferAllOwnerships() internal {
        address pendingOwner = owner();
        string memory ownerLabel = _addressLabel(pendingOwner);
        uint256 length = _pendingOwnershipTransfers.length();
        for (uint256 i = 0; i < length; i++) {
            address deployed = _pendingOwnershipTransfers.at(i);
            string memory salt = _ownershipTransferSalts[deployed];
            address currentOwner = IBaoOwnable(deployed).owner();
            if (currentOwner == pendingOwner) {
                console.log("        %s -> %s (already owned)", salt, ownerLabel);
            } else {
                console.log("        %s -> %s", salt, ownerLabel);
                IBaoOwnable(deployed).transferOwnership(pendingOwner);
            }
        }
        // Clear after transfer - iterate backwards to avoid index issues
        while (_pendingOwnershipTransfers.length() > 0) {
            address addr = _pendingOwnershipTransfers.at(_pendingOwnershipTransfers.length() - 1);
            _pendingOwnershipTransfers.remove(addr);
            delete _ownershipTransferSalts[addr];
        }
    }

    /// @notice Get count of contracts pending ownership transfer.
    function _pendingOwnershipCount() internal view returns (uint256) {
        return _pendingOwnershipTransfers.length();
    }

    /// @notice Look up a human-readable label for an address.
    /// @dev Uses getWellKnownAddresses() to find a label. Falls back to hex address.
    function _addressLabel(address addr) internal view virtual returns (string memory) {
        WellKnownAddress[] memory known = getWellKnownAddresses();
        for (uint256 i = 0; i < known.length; i++) {
            if (known[i].addr == addr) {
                return known[i].label;
            }
        }
        return Strings.toHexString(addr);
    }

    // ========== SALT ==========
    // Salt KEYS are built with SaltString.key(...) — the single key-builder, reachable from deployers,
    // configs, libraries and tests alike (FactoryDeployer no longer exposes its own _key). The campaign
    // PREFIX is deploy-run state held here and applied by _saltString below.

    /// @notice Construct full salt string from a local key by prepending the campaign salt prefix.
    /// @dev The prefix is deploy-run state (held here); the join itself routes through SaltString.
    function _saltString(string memory key) internal view returns (string memory) {
        string memory prefix = saltPrefix();
        if (bytes(prefix).length == 0) {
            revert SaltPrefixNotSet();
        }
        return SaltString.key(prefix, key);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict address for a local key.
    /// @dev Prepends salt prefix, hashes, and queries BaoFactory.
    function _predictAddress(string memory key) internal returns (address) {
        return _predictAddressFromFullSalt(_saltString(key));
    }

    /// @notice Predict address for a complete salt string (e.g., "harbor_v1::ETH::fxUSD::minter")
    /// @dev Also labels the address with the salt for readable traces.
    function _predictAddressFromFullSalt(string memory fullSalt) private returns (address addr) {
        bytes32 salt = keccak256(abi.encodePacked(fullSalt));
        addr = IBaoFactory(baoFactory()).predictAddress(salt);
        vm.label(addr, fullSalt);
    }

    // ========== DEPLOY AND RECORD ==========
    // Two deployment paths:
    //   _deployProxyAndRecord          — Direct: ERC1967Proxy(impl, initData) in one step.
    //                                    Default for new contracts (HarborOwnable, HarborFixedOwnable).
    //   _deployProxyViaStubAndRecord   — Via UUPSProxyDeployStub: needed for BaoOwnable contracts whose
    //                                    _initializeOwner(finalOwner) uses msg.sender as temp owner.
    //                                    The stub ensures msg.sender = FactoryDeployer, not BaoFactory.
    //
    // Implementations are recorded separately by callers via _recordImplementation, before invoking
    // either deploy* function. This pattern lets callers expose a virtual deploy*Implementation
    // helper that can be overridden in tests to substitute a mock implementation contract.

    // ── Direct path (default) ──────────────────────────────────────

    /// @notice Deploy proxy (direct) and record proxy in state.
    /// @dev Caller must record the implementation via _recordImplementation before calling.
    function _deployProxyAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        bytes memory initData
    ) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix(), "::", proxyId));
        proxy = _deployProxy(baoFactory(), salt, implementation, initData);
        _recordProxyAndRegister(stateData, proxyId, proxy, implementation);
    }

    // ── Via-stub path (legacy BaoOwnable) ──────────────────────────

    /// @notice Deploy proxy via stub and record proxy in state.
    /// @dev Caller must record the implementation via _recordImplementation before calling.
    function _deployProxyViaStubAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        bytes memory initData
    ) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix(), "::", proxyId));
        proxy = _deployProxyViaStub(baoFactory(), salt, implementation, initData);
        _recordProxyAndRegister(stateData, proxyId, proxy, implementation);
    }

    // ── Shared recording ───────────────────────────────────────────

    /// @notice Record an implementation in deployment state.
    /// @dev Each implementation must be recorded exactly once. Callers typically expose this
    ///      from a virtual deploy*Implementation helper so tests can override the helper to
    ///      substitute a mock implementation address.
    function _recordImplementation(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        string memory contractSource,
        string memory contractType,
        address implementation
    ) internal view {
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
    }

    function _recordProxyAndRegister(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address proxy,
        address implementation
    ) private {
        console.log("        Proxy: %s", proxy);
        _registerForOwnershipTransfer(proxy, _saltString(proxyId));
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
    }

    // ========== IMPLEMENTATION DETAILS ==========

    /// @notice Get the implementation address from an ERC1967 proxy.
    /// @dev Uses Foundry vm.load to read the ERC1967 implementation slot from the proxy's storage.
    function _getImplementation(address proxy) internal view returns (address) {
        // ERC1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 value = vm.load(proxy, slot);
        return address(uint160(uint256(value)));
    }

    /// @notice Deploy proxy directly via BaoFactory CREATE3: ERC1967Proxy(impl, initData).
    /// @dev Default path. No stub needed — suitable for HarborOwnable (explicit deployer) and
    ///      HarborFixedOwnable (no initializer) contracts.
    function _deployProxy(
        address factory,
        bytes32 salt,
        address implementation,
        bytes memory initData
    ) private returns (address proxy) {
        IBaoFactory baoFactoryContract = IBaoFactory(factory);
        address predictedProxy = baoFactoryContract.predictAddress(salt);

        proxy = baoFactoryContract.deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData)),
            salt
        );
        require(proxy == predictedProxy, "Proxy address mismatch");
    }

    /// @notice Deploy proxy via UUPSProxyDeployStub then upgrade to real implementation.
    /// @dev Legacy path for BaoOwnable contracts whose _initializeOwner(finalOwner) uses msg.sender.
    ///      The stub ensures msg.sender = FactoryDeployer (not BaoFactory) during initialization.
    function _deployProxyViaStub(
        address factory,
        bytes32 salt,
        address implementation,
        bytes memory initData
    ) private returns (address proxy) {
        IBaoFactory baoFactoryContract = IBaoFactory(factory);
        address predictedProxy = baoFactoryContract.predictAddress(salt);

        // Step 1: deploy proxy pointing at stub
        UUPSProxyDeployStub stub = _getOrDeployStub();
        proxy = baoFactoryContract.deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt
        );
        require(proxy == predictedProxy, "Proxy address mismatch");

        // Step 2: upgrade to real implementation and initialize (msg.sender = this contract, owner per stub)
        if (initData.length > 0) {
            IUUPSProxyUpgrade(proxy).upgradeToAndCall(implementation, initData);
        } else {
            IUUPSProxyUpgrade(proxy).upgradeTo(implementation);
        }
    }
}
