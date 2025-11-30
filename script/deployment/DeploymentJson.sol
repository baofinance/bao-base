// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {LibString} from "@solady/utils/LibString.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataJson} from "@bao-script/deployment/DeploymentDataJson.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O
 * @dev Extends base Deployment with:
 *      - JSON file path resolution (input/output)
 *      - Timestamp-based file naming
 *      - DeploymentDataJson integration
 *      Subclasses implement _createDataLayer to choose specific JSON data implementation
 */
abstract contract DeploymentJson is Deployment {
    using LibString for string;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private _systemSaltString;
    string private _network;
    string private _filename;
    // TODO: this is a hack - _data (from Deployment) and _dataJson should be unified
    // The issue is: Memory and Json implementations are at different levels (Json extends Memory)
    // Ideally they'd be peers implementing the same interface, with Deployment holding just _data
    DeploymentDataJson _dataJson;
    bool _suppressPersistence = false;

    constructor() {
        _filename = _formatTimestamp(block.timestamp);
        _dataJson = new DeploymentDataJson(this);
        _data = _dataJson; // Ensure _data always points to the same object
    }

    // ============================================================================
    // Abstract Methods for JSON Configuration
    // ============================================================================

    function _afterValueChanged(string memory /* key */) internal virtual override {
        if (!_suppressPersistence) {
            save();
        }
    }

    function save() internal virtual {
        string memory path = string.concat(_getOutputConfigDir(), "/", _getFilename(), ".json");
        VM.writeJson(_dataJson.toJson(), path);
    }

    // ============================================================================
    // Path Calculation
    // ============================================================================

    /// @notice Get base directory for deployment files
    /// @dev Override in test classes to use results/ instead of ./
    /// @return Base directory path
    function _getPrefix() internal virtual returns (string memory) {
        return ".";
    }

    function _getRoot() private returns (string memory) {
        return string.concat(_getPrefix(), "/deployments");
    }

    function _getStartConfigDir() internal returns (string memory) {
        return string.concat(_getRoot(), "/", _systemSaltString);
    }

    function _getOutputConfigDir() internal returns (string memory) {
        if (bytes(_network).length > 0) return string.concat(_getRoot(), "/", _systemSaltString, "/", _network);
        else return string.concat(_getRoot(), "/", _systemSaltString);
    }

    function _getFilename() internal view virtual returns (string memory filename) {
        filename = _filename;
    }
    // ============================================================================
    // Lifecycle Override with JSON Support
    // ============================================================================
    function _requireNetwork(string memory network_) internal virtual {
        require(bytes(network_).length > 0, "cannot have a null network string");
    }

    /// @notice Initialize data layer with JSON file paths
    /// @dev Implements abstract method from base Deployment
    /// @param network_ Network name
    /// @param systemSaltString_ System salt string
    /// @param startPoint Start point for input resolution
    /// @dev Subclasses choose: DeploymentDataJson, DeploymentDataJsonTesting, etc.
    function _createDeploymentData(
        string memory network_,
        string memory systemSaltString_,
        string memory startPoint
    ) internal virtual override returns (IDeploymentDataWritable) {
        _requireNetwork(network_);
        require(bytes(systemSaltString_).length > 0, "cannot have a null system salt string");
        _network = network_;
        _systemSaltString = systemSaltString_;

        // now load the data from the specified file
        string memory path;
        if (bytes(startPoint).length == 0 || startPoint.eq("first")) {
            path = string.concat(_getStartConfigDir(), "/config.json");
        } else if (startPoint.eq("latest")) {
            path = _findLatestFile();
        } else {
            path = string.concat(_getOutputConfigDir(), "/", startPoint, ".json");
        }
        _suppressPersistence = true; // we don't want the loading to write out each change, on loading
        _dataJson.fromJson(VM.readFile(path));
        _suppressPersistence = false;

        return _dataJson;
    }

    /// @notice Find the latest JSON file in the output directory
    /// @dev Uses lexicographic sorting of ISO 8601 timestamps
    /// @return Full path to the latest JSON file
    function _findLatestFile() private returns (string memory) {
        string memory dir = _getOutputConfigDir();
        Vm.DirEntry[] memory entries = VM.readDir(dir, 1); // maxDepth=1, no recursion

        string memory latestFile;
        string memory latestName;

        for (uint256 i = 0; i < entries.length; i++) {
            // Skip directories, symlinks, and errors
            if (entries[i].isDir || entries[i].isSymlink || bytes(entries[i].errorMessage).length > 0) {
                continue;
            }

            // Extract filename from path
            string memory fullPath = entries[i].path;
            string memory filename = _extractFilename(fullPath);

            // Skip config.json
            if (filename.eq("config.json")) {
                continue;
            }

            // Only consider .json files
            if (!filename.endsWith(".json")) {
                continue;
            }

            // Compare filenames (ISO 8601 timestamps sort lexicographically)
            if (bytes(latestName).length == 0 || _isGreater(filename, latestName)) {
                latestName = filename;
                latestFile = fullPath;
            }
        }

        require(bytes(latestFile).length > 0, "No deployment files found in directory");
        return latestFile;
    }

    /// @notice Extract filename from a full path
    function _extractFilename(string memory path) private pure returns (string memory) {
        uint256 lastSlashIndex = path.lastIndexOf("/");

        // If not found, return whole path
        if (lastSlashIndex == type(uint256).max) {
            return path;
        }

        // Extract substring after last slash (lastIndexOf returns byte index)
        bytes memory pathBytes = bytes(path);
        bytes memory result = new bytes(pathBytes.length - lastSlashIndex - 1);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = pathBytes[lastSlashIndex + 1 + i];
        }

        return string(result);
    }

    /// @notice Compare two strings lexicographically (a > b)
    function _isGreater(string memory a, string memory b) private pure returns (bool) {
        bytes memory aBytes = bytes(a);
        bytes memory bBytes = bytes(b);

        uint256 minLen = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;

        for (uint256 i = 0; i < minLen; i++) {
            if (aBytes[i] > bBytes[i]) {
                return true;
            } else if (aBytes[i] < bBytes[i]) {
                return false;
            }
        }

        // If all compared bytes are equal, longer string is greater
        return aBytes.length > bBytes.length;
    }
}
