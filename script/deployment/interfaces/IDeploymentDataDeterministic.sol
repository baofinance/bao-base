// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IDeploymentDataDeterministic
 * @notice Optional interface for data layers that support deterministic filenames
 */
interface IDeploymentDataDeterministic {
    function setFilename(string memory filename) external;
    function setNetworkLabel(string memory label) external;
}
