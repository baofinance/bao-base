// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title DeploymentConfig
/// @notice Reads deployment settings from JSON, handling contract overrides and conflict directives.
library DeploymentConfig {
    using stdJson for string;

    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Immutable snapshot of a loaded JSON configuration.
    struct SourceJson {
        string text;
        string filepath; // reserved for future provenance metadata
    }

    /// @notice Resolution policy when config and log disagree.
    enum ConflictResolution {
        Unspecified,
        PreferConfig,
        PreferLog
    }

    /// @notice Raised when a requested value is not present anywhere in the config hierarchy.
    error ConfigValueMissing(string contractKey, string fieldPath);
    /// @notice Raised when a conflict directive is not recognised.
    error ConfigUnknownDirective(string key, string directive);

    /// @notice Load configuration file contents into memory.
    /// @param path Filesystem path to the JSON document.
    /// @return Loaded config source including original text.
    function fromJsonFile(string memory path) internal view returns (SourceJson memory) {
        string memory text = VM.readFile(path);
        return SourceJson({text: text, filepath: ""});
    }

    /// @notice Construct a config source from an already-fetched JSON string.
    /// @param text Entire JSON payload.
    function fromJson(string memory text) internal pure returns (SourceJson memory) {
        return SourceJson({text: text, filepath: ""});
    }

    /// @notice Check whether a field exists for a given contract key.
    function has(
        SourceJson memory config,
        string memory contractKey,
        string memory fieldPath
    ) internal view returns (bool) {
        (bool found, ) = _resolvePointer(config, contractKey, fieldPath);
        return found;
    }

    /// @notice Fetch an address value with override resolution.
    function get(
        SourceJson memory config,
        string memory contractKey,
        string memory fieldPath
    ) internal view returns (address) {
        string memory pointer = _requirePointer(config, contractKey, fieldPath);
        return config.text.readAddress(pointer);
    }

    /// @notice Fetch a uint value with override resolution.
    function getUint(
        SourceJson memory config,
        string memory contractKey,
        string memory fieldPath
    ) internal view returns (uint256) {
        string memory pointer = _requirePointer(config, contractKey, fieldPath);
        return config.text.readUint(pointer);
    }

    /// @notice Fetch a string value with override resolution.
    function getString(
        SourceJson memory config,
        string memory contractKey,
        string memory fieldPath
    ) internal view returns (string memory) {
        string memory pointer = _requirePointer(config, contractKey, fieldPath);
        return config.text.readString(pointer);
    }

    /// @notice Determine how to reconcile config/log conflicts for a given key path.
    function conflictResolution(
        SourceJson memory config,
        string memory key
    ) internal view returns (ConflictResolution) {
        string memory pointer = _buildPointer("$.conflicts", key, "");
        if (!_exists(config, pointer)) {
            return ConflictResolution.Unspecified;
        }

        string memory directive = config.text.readString(pointer);
        bytes32 directiveHash = keccak256(bytes(directive));

        if (directiveHash == keccak256(bytes("prefer-config"))) {
            return ConflictResolution.PreferConfig;
        }
        if (directiveHash == keccak256(bytes("prefer-log"))) {
            return ConflictResolution.PreferLog;
        }

        revert ConfigUnknownDirective(key, directive);
    }

    /// @dev Resolve a JSON pointer or revert if absent.
    function _requirePointer(
        SourceJson memory config,
        string memory contractKey,
        string memory fieldPath
    ) private view returns (string memory) {
        (bool found, string memory pointer) = _resolvePointer(config, contractKey, fieldPath);
        if (!found) {
            revert ConfigValueMissing(contractKey, fieldPath);
        }
        return pointer;
    }

    /// @dev Resolve pointer precedence: contract override, contract defaults, then global defaults.
    function _resolvePointer(
        SourceJson memory config,
        string memory contractKey,
        string memory fieldPath
    ) private view returns (bool, string memory) {
        bool contractKnown;
        if (bytes(contractKey).length != 0) {
            string memory contractPointer = _buildPointer("$.contracts", contractKey, fieldPath);
            if (_exists(config, contractPointer)) {
                return (true, contractPointer);
            }

            string memory contractDefault = _buildPointer("$.defaults", contractKey, fieldPath);
            if (_exists(config, contractDefault)) {
                return (true, contractDefault);
            }

            contractKnown =
                _exists(config, _buildPointer("$.contracts", contractKey, "")) ||
                _exists(config, _buildPointer("$.defaults", contractKey, ""));
        }

        if (bytes(contractKey).length == 0 || contractKnown) {
            string memory globalDefault = _buildPointer("$.defaults", "", fieldPath);
            if (_exists(config, globalDefault)) {
                return (true, globalDefault);
            }
        }

        return (false, "");
    }

    /// @dev Assemble a dotted JSON pointer segment.
    function _buildPointer(
        string memory prefix,
        string memory key,
        string memory fieldPath
    ) private pure returns (string memory) {
        string memory pointer = prefix;
        if (bytes(key).length != 0) {
            pointer = string.concat(pointer, ".", key);
        }
        if (bytes(fieldPath).length != 0) {
            pointer = string.concat(pointer, ".", fieldPath);
        }
        return pointer;
    }

    /// @dev Test whether a pointer resolves to a non-null JSON fragment.
    function _exists(SourceJson memory config, string memory pointer) private view returns (bool) {
        if (bytes(pointer).length == 0) {
            return false;
        }
        (bool success, bytes memory returnData) = address(VM).staticcall(
            abi.encodeWithSignature("parseJson(string,string)", config.text, pointer)
        );
        if (!success) {
            return false;
        }
        bytes memory value = abi.decode(returnData, (bytes));
        if (value.length == 0) {
            return false;
        }
        if (keccak256(value) == keccak256(bytes("null"))) {
            return false;
        }
        return true;
    }
}
