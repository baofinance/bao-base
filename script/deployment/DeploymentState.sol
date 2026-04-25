// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {JsonSerializer} from "@bao-script/deployment/JsonSerializer.sol";
import {JsonParser} from "@bao-script/deployment/JsonParser.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

/// @notice Persistent deployment state management backed by JSON files.
/// @dev Library form to avoid on-chain deployment/broadcast in scripts.
library DeploymentState {
    using stdJson for string;
    using LibString for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error DuplicateImplementation(address implementation);
    error DuplicateProxy(string id);
    error DuplicateProxyAddress(address proxy);
    error ProxyKeyRequiredForImplementation();
    error ImplementationAddressRequired();
    error ProxyKeyRequired();
    error ProxyAddressRequired();

    /// @notice Resolve the deployment state directory.
    /// @dev Reads DEPLOY_STATE_DIR env var. Used by SafeBatch for the batch subdirectory.
    function resolveDirectory() internal view returns (string memory) {
        return vm.envString("DEPLOY_STATE_DIR");
    }

    /// @notice Load deployment state from an explicit file path.
    /// @dev Returns empty state if the file does not exist.
    function load(string memory path) internal view returns (DeploymentTypes.State memory state) {
        string memory json = vm.exists(path) ? vm.readFile(path) : "";
        return JsonParser.parseStateJson(json);
    }

    /// @notice Save state to disk atomically (write to temp file, then rename).
    /// @dev Uses ffi to call `mv` for atomic rename since Foundry lacks a rename cheatcode.
    function save(DeploymentTypes.State memory state, string memory path) internal {
        _ensureDirectory();

        string memory json = JsonSerializer.renderState(state);
        string memory tempPath = string.concat(path, ".tmp");

        // Write to temp file (pretty-printed via stdJson)
        json.write(tempPath);

        // Atomic rename: mv temp -> final
        string[] memory mvCmd = new string[](3);
        mvCmd[0] = "mv";
        mvCmd[1] = tempPath;
        mvCmd[2] = path;
        vm.ffi(mvCmd);
    }

    /// @notice Record an implementation. Reverts if the address already exists in state.
    /// @dev Multiple implementations can exist for the same proxy key
    ///      (e.g., v1, v2 after upgrade). The proxy record points to the current one.
    function recordImplementation(
        DeploymentTypes.State memory state,
        DeploymentTypes.ImplementationRecord memory rec
    ) internal pure {
        if (bytes(rec.proxy).length == 0) revert ProxyKeyRequiredForImplementation();
        if (rec.implementation == address(0)) revert ImplementationAddressRequired();

        uint256 length = state.implementations.length;
        for (uint256 i = 0; i < length; ++i) {
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
    }

    /// @notice Record a proxy. Reverts if the ID or address already exists in state.
    function recordProxy(DeploymentTypes.State memory state, DeploymentTypes.ProxyRecord memory rec) internal pure {
        if (bytes(rec.id).length == 0) revert ProxyKeyRequired();
        if (rec.proxy == address(0)) revert ProxyAddressRequired();

        uint256 length = state.proxies.length;
        for (uint256 i = 0; i < length; ++i) {
            if (LibString.eq(state.proxies[i].id, rec.id)) revert DuplicateProxy(rec.id);
            if (state.proxies[i].proxy == rec.proxy) revert DuplicateProxyAddress(rec.proxy);
        }

        DeploymentTypes.ProxyRecord[] memory updated = new DeploymentTypes.ProxyRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.proxies[i];
        }
        updated[length] = rec;
        state.proxies = updated;
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

    function _ensureDirectory() private {
        vm.createDir(resolveDirectory(), true);
    }
}
