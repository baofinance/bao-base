// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDeploymentDataWritable} from "./IDeploymentDataWritable.sol";

/**
 * @title IDeploymentDataJson
 * @notice Extended interface for JSON-backed deployment data with file I/O
 */
interface IDeploymentDataJson is IDeploymentDataWritable {
    /// @notice Load deployment data from JSON file
    /// @param inputPath Absolute path to input JSON file
    function loadFromFile(string memory inputPath) external;

    /// @notice Set output path and enable automatic persistence
    /// @param outputPath Absolute path where JSON should be saved
    function setOutputPath(string memory outputPath) external;

    /// @notice Get current output path
    function getOutputPath() external view returns (string memory);
}
