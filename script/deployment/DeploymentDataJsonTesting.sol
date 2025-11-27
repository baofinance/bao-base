// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeploymentDataJson} from "./DeploymentDataJson.sol";
import {DeploymentKeys} from "./DeploymentKeys.sol";

/**
 * @title DeploymentDataJsonTesting
 * @notice Testing variant with optional sequence numbering for tracking update progression
 * @dev Call enableSequencing() to add .001, .002, .003 suffixes on subsequent writes
 *      By default, overwrites the same file like production deployments
 */
contract DeploymentDataJsonTesting is DeploymentDataJson {
    string private _baseOutputPath; // Path without sequence suffix
    uint256 private _sequenceNumber; // Incremented on each save
    bool private _sequencingEnabled; // Whether to append sequence numbers

    constructor(DeploymentKeys keyRegistry, string memory inputPath) DeploymentDataJson(keyRegistry, inputPath) {}

    /// @notice Enable sequence numbering for capturing update phases
    /// @dev Call this before writes to create .001, .002, .003 files instead of overwriting
    function enableSequencing() external {
        _sequencingEnabled = true;
    }

    /// @notice Override to track base path for sequencing
    function setOutputPath(string memory outputPath) external override {
        _baseOutputPath = outputPath;
        _outputPath = outputPath;
        _sequenceNumber = 1; // Start sequence at 1
    }

    /// @notice Override to add sequence numbers to all saves (if enabled)
    function _saveToFile() internal override {
        if (_sequencingEnabled) {
            // Add sequence number to every save (starting from 1)
            _outputPath = _appendSequence(_baseOutputPath, _sequenceNumber);
            _sequenceNumber++;
        }

        // Call parent to do the actual save
        super._saveToFile();
    }

    /// @notice Append sequence number to filename (e.g., "file.json" -> "file.001.json")
    /// @param path Base file path
    /// @param seq Sequence number
    /// @return Path with sequence inserted before extension
    function _appendSequence(string memory path, uint256 seq) private pure returns (string memory) {
        bytes memory pathBytes = bytes(path);

        // Find the last dot (extension separator)
        uint256 lastDot = 0;
        bool foundDot = false;
        for (uint256 i = pathBytes.length; i > 0; i--) {
            if (pathBytes[i - 1] == 0x2E) {
                // '.'
                lastDot = i - 1;
                foundDot = true;
                break;
            }
        }

        // If no extension found, just append
        if (!foundDot) {
            return string.concat(path, ".", _formatSequence(seq));
        }

        // Split at extension: "path/file" + ".001" + ".json"
        bytes memory beforeExt = new bytes(lastDot);
        for (uint256 i = 0; i < lastDot; i++) {
            beforeExt[i] = pathBytes[i];
        }

        bytes memory afterExt = new bytes(pathBytes.length - lastDot);
        for (uint256 i = 0; i < afterExt.length; i++) {
            afterExt[i] = pathBytes[lastDot + i];
        }

        return string.concat(string(beforeExt), ".", _formatSequence(seq), string(afterExt));
    }

    /// @notice Format sequence number with leading zeros (001, 002, etc.)
    /// @param seq Sequence number
    /// @return Three-digit string
    function _formatSequence(uint256 seq) private pure returns (string memory) {
        require(seq < 1000, "Sequence overflow");
        if (seq < 10) return string.concat("00", _uint2str(seq));
        if (seq < 100) return string.concat("0", _uint2str(seq));
        return _uint2str(seq);
    }

    /// @notice Convert uint to string
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
}
