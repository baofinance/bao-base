// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataJson} from "@bao-script/deployment/DeploymentDataJson.sol";

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
    // ============================================================================
    // Abstract Methods for JSON Configuration
    // ============================================================================

    /// @notice Get base directory for deployment files
    /// @dev Override in test classes to use results/ instead of ./
    /// @return Base directory path
    function _getDeploymentBaseDir() internal view virtual returns (string memory) {
        return ".";
    }

    /// @notice Whether to use system salt subdirectory in path
    /// @dev Production uses salt subdirs, tests may override to false
    /// @return True if paths should include system salt subdirectory
    function _useSystemSaltSubdir() internal view virtual returns (bool) {
        return true;
    }

    // ============================================================================
    // Path Calculation
    // ============================================================================

    /// @notice Build input file path from timestamp keyword
    /// @param network Network name
    /// @param systemSaltString System salt
    /// @param inputTimestamp "first", "latest", ISO timestamp, or empty for config.json
    /// @return Absolute path to input JSON file
    function _resolveInputPath(
        string memory network,
        string memory systemSaltString,
        string memory inputTimestamp
    ) internal view returns (string memory) {
        string memory baseTree = _buildBaseTree(systemSaltString);

        if (bytes(inputTimestamp).length == 0 || _streq(inputTimestamp, "first")) {
            return string.concat(baseTree, "/config.json");
        }

        // "latest" and explicit timestamps need the network directory
        string memory networkDir = string.concat(baseTree, "/", network);

        if (_streq(inputTimestamp, "latest")) {
            // TODO: implement latest file finding if needed
            revert("Latest file resolution not yet implemented");
        }

        return string.concat(networkDir, "/", inputTimestamp, ".json");
    }

    /// @notice Build output file path
    /// @param network Network name
    /// @param systemSaltString System salt
    /// @return Absolute path where JSON should be written
    function _buildOutputPath(
        string memory network,
        string memory systemSaltString
    ) internal view returns (string memory) {
        string memory networkDir = string.concat(_buildBaseTree(systemSaltString), "/", network);
        string memory timestamp = _generateTimestamp();
        return string.concat(networkDir, "/", timestamp, ".json");
    }

    function _buildBaseTree(string memory systemSaltString) private view returns (string memory) {
        string memory tree = string.concat(_getDeploymentBaseDir(), "/deployments");
        if (_useSystemSaltSubdir() && bytes(systemSaltString).length != 0) {
            tree = string.concat(tree, "/", systemSaltString);
        }
        return tree;
    }

    function _generateTimestamp() private view returns (string memory) {
        // Simple ISO 8601 timestamp
        uint256 ts = block.timestamp;
        return _formatTimestamp(ts);
    }

    function _formatTimestamp(uint256 ts) private pure returns (string memory) {
        // Simplified timestamp formatting
        return string(abi.encodePacked("deployment-", _uint2str(ts)));
    }

    function _uint2str(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits = 0;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _streq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ============================================================================
    // Lifecycle Override with JSON Support
    // ============================================================================

    /// @notice Initialize data layer with JSON file paths
    /// @dev Implements abstract method from base Deployment
    /// @param network Network name
    /// @param systemSaltString System salt string
    /// @param startPoint Start point for input resolution
    /// @dev Subclasses choose: DeploymentDataJson, DeploymentDataJsonTesting, etc.
    function _createDeploymentData(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) internal virtual override returns (IDeploymentDataWritable data) {
        string memory inputPath = _resolveInputPath(network, systemSaltString, startPoint);
        string memory outputPath = _buildOutputPath(network, systemSaltString);
        data = new DeploymentDataJson(this, inputPath);
        DeploymentDataJson(address(data)).setOutputPath(outputPath);
    }
}
