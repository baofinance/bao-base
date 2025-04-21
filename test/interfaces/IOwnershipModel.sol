// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMockImplementation} from "../interfaces/IMockImplementation.sol";

/**
 * @title IOwnershipModel
 * @notice Interface for ownership model adapters
 * @dev Strategy Pattern: Defines common interface for all ownership models
 */
interface IOwnershipModel {
    function deploy(address initialOwner, uint256 initialValue) external;
    function upgrade(address newOwner, uint256 newValue) external;
    function deployImplementation(address initialOwner) external;
    function upgradeTo(address implementation, uint256 newValue) external;
    function implementation() external view returns (IMockImplementation);
    function proxy() external view returns (IMockImplementation);
    function unauthorizedSelector() external pure returns (bytes4);
}
