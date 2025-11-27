// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeploymentKeys} from "./DeploymentKeys.sol";
import {DeploymentDataStore} from "./DeploymentDataStore.sol";
import {IDeploymentDataJson} from "./interfaces/IDeploymentDataJson.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentDataJson
 * @notice JSON-backed deployment data implementation built on top of DeploymentDataStore
 * @dev Pure persistence layer - caller provides all paths
 */
contract DeploymentDataJson is DeploymentDataStore, IDeploymentDataJson {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal _outputPath;

    constructor(DeploymentKeys keyRegistry, string memory inputPath) DeploymentDataStore(keyRegistry) {
        // Load input file if it exists
        if (bytes(inputPath).length > 0 && vm.exists(inputPath)) {
            string memory existingJson = vm.readFile(inputPath);
            _loadFromJson(existingJson);
        }
    }

    // ============ Public API ============

    /// @notice Load deployment data from JSON file
    /// @param inputPath Absolute path to input JSON file
    function loadFromFile(string memory inputPath) external {
        if (vm.exists(inputPath)) {
            string memory existingJson = vm.readFile(inputPath);
            _loadFromJson(existingJson);
        }
    }

    /// @notice Set output path and enable automatic persistence
    /// @param outputPath Absolute path where JSON should be saved
    function setOutputPath(string memory outputPath) external virtual {
        _outputPath = outputPath;
    }

    /// @notice Get current output path
    function getOutputPath() external view returns (string memory) {
        return _outputPath;
    }

    // ============ Hooks ============

    function _afterValueChanged(string memory) internal override {
        if (_shouldPersist()) {
            _saveToFile();
        }
    }

    /// @notice Check if automatic persistence is enabled
    /// @dev Virtual hook - override to disable persistence conditionally
    /// @return True if values should be automatically saved to file
    function _shouldPersist() internal view virtual returns (bool) {
        return bytes(_outputPath).length > 0;
    }

    // ============ Persistence ============

    function _saveToFile() internal virtual {
        require(bytes(_outputPath).length > 0, "Output path not set");
        // Extract directory from output path and ensure it exists
        string memory dir = _dirname(_outputPath);
        if (bytes(dir).length > 0) {
            vm.createDir(dir, true);
        }
        vm.writeJson(_currentJson(), _outputPath);
    }

    function _dirname(string memory path) internal pure returns (string memory) {
        bytes memory pathBytes = bytes(path);
        if (pathBytes.length == 0) return "";

        uint256 lastSlash = 0;
        bool foundSlash = false;
        for (uint256 i = 0; i < pathBytes.length; i++) {
            if (pathBytes[i] == 0x2F) {
                lastSlash = i;
                foundSlash = true;
            }
        }

        if (!foundSlash) return "";

        bytes memory result = new bytes(lastSlash);
        for (uint256 i = 0; i < lastSlash; i++) {
            result[i] = pathBytes[i];
        }
        return string(result);
    }
}
