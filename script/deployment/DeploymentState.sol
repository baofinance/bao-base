// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {JsonSerializer} from "./JsonSerializer.sol";
import {JsonParser} from "./JsonParser.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Persistent deployment state management backed by JSON files.
/// @dev Library form to avoid on-chain deployment/broadcast in scripts.
library DeploymentState {
    using stdJson for string;
    using LibString for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error DuplicateImplementation(address implementation);
    error DuplicateImplementationForProxy(string proxy);
    error DuplicateProxy(string id);
    error DuplicateProxyAddress(address proxy);
    error ProxyKeyRequiredForImplementation();
    error ImplementationAddressRequired();
    error ProxyKeyRequired();
    error ProxyAddressRequired();

    function resolveDirectory(
        string memory network,
        string memory directoryPrefix
    ) private view returns (string memory) {
        // DEPLOY_STATE_SUBDIR: optional subdirectory between deployments/ and network
        // e.g., "local" → deployments/local/mainnet/
        string memory subdir = vm.envOr("DEPLOY_STATE_SUBDIR", string(""));
        return
            string.concat(
                vm.projectRoot(),
                "/",
                (directoryPrefix.eq("") ? "" : string.concat(directoryPrefix, "/")),
                "deployments/",
                (subdir.eq("") ? "" : string.concat(subdir, "/")),
                network
            );
    }

    function resolvePath(
        string memory network,
        string memory saltPrefix,
        string memory directoryPrefix
    ) internal view returns (string memory) {
        return string.concat(resolveDirectory(network, directoryPrefix), "/", saltPrefix, ".state.json");
    }

    function load(
        string memory network,
        string memory saltPrefix
    ) internal returns (DeploymentTypes.State memory state) {
        return load(network, saltPrefix, "");
    }

    function load(
        string memory network,
        string memory saltPrefix,
        string memory directoryPrefix
    ) internal returns (DeploymentTypes.State memory state) {
        _ensureDirectory(network, directoryPrefix);

        string memory path = resolvePath(network, saltPrefix, directoryPrefix);
        string memory json = _readStateFile(path);
        state = JsonParser.parseStateJson(json);
        state.network = network;
        state.saltPrefix = saltPrefix;
        return state;
    }

    function save(DeploymentTypes.State memory state) internal {
        save(state, "");
    }

    function save(DeploymentTypes.State memory state, string memory directoryPrefix) internal {
        _ensureDirectory(state.network, directoryPrefix);

        string memory json = JsonSerializer.renderState(state);

        string memory path = resolvePath(state.network, state.saltPrefix, directoryPrefix);
        // vm.writeFile(path, json); // don't do this as we want the json pretty-printed
        json.write(path);
    }

    /// @notice Record an implementation. Idempotent: if exact same record exists, returns true.
    /// @return alreadyExists True if the record already existed (no change made).
    function recordImplementation(
        DeploymentTypes.State memory state,
        DeploymentTypes.ImplementationRecord memory rec
    ) internal pure returns (bool alreadyExists) {
        if (bytes(rec.proxy).length == 0) revert ProxyKeyRequiredForImplementation();
        if (rec.implementation == address(0)) revert ImplementationAddressRequired();

        uint256 length = state.implementations.length;
        for (uint256 i = 0; i < length; ++i) {
            if (LibString.eq(state.implementations[i].proxy, rec.proxy)) {
                // Same proxy key - check if it's an identical record (idempotent) or a conflict
                if (state.implementations[i].implementation == rec.implementation) {
                    return true; // Idempotent: exact same record already exists
                }
                revert DuplicateImplementationForProxy(rec.proxy);
            }
            if (state.implementations[i].implementation == rec.implementation) {
                revert DuplicateImplementation(rec.implementation);
            }
        }

        DeploymentTypes.ImplementationRecord[] memory updated = new DeploymentTypes.ImplementationRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.implementations[i];
        }
        updated[length] = rec;
        state.implementations = updated;
        return false;
    }

    /// @notice Record a proxy. Idempotent: if exact same record exists, returns true.
    /// @return alreadyExists True if the record already existed (no change made).
    function recordProxy(
        DeploymentTypes.State memory state,
        DeploymentTypes.ProxyRecord memory rec
    ) internal pure returns (bool alreadyExists) {
        if (bytes(rec.id).length == 0) revert ProxyKeyRequired();
        if (rec.proxy == address(0)) revert ProxyAddressRequired();

        uint256 length = state.proxies.length;
        for (uint256 i = 0; i < length; ++i) {
            if (LibString.eq(state.proxies[i].id, rec.id)) {
                // Same ID - check if it's an identical record (idempotent) or a conflict
                if (state.proxies[i].proxy == rec.proxy) {
                    return true; // Idempotent: exact same record already exists
                }
                revert DuplicateProxy(rec.id);
            }
            if (state.proxies[i].proxy == rec.proxy) revert DuplicateProxyAddress(rec.proxy);
        }

        DeploymentTypes.ProxyRecord[] memory updated = new DeploymentTypes.ProxyRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.proxies[i];
        }
        updated[length] = rec;
        state.proxies = updated;
        return false;
    }

    /// @notice Check if a proxy with given ID exists in state.
    function hasProxy(DeploymentTypes.State memory state, string memory id) internal pure returns (bool) {
        for (uint256 i = 0; i < state.proxies.length; ++i) {
            if (LibString.eq(state.proxies[i].id, id)) return true;
        }
        return false;
    }

    /// @notice Check if an implementation for given proxy key exists in state.
    function hasImplementation(
        DeploymentTypes.State memory state,
        string memory proxyKey
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < state.implementations.length; ++i) {
            if (LibString.eq(state.implementations[i].proxy, proxyKey)) return true;
        }
        return false;
    }

    function _ensureDirectory(string memory network, string memory directoryPrefix) private {
        vm.createDir(resolveDirectory(network, directoryPrefix), true);
    }

    function _readStateFile(string memory path) internal view returns (string memory) {
        if (!vm.exists(path)) {
            return "";
        }
        return vm.readFile(path);
    }
}
