// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMockImplementation
 * @notice Common interface for all mock implementation contracts
 * @dev Only contains methods common to all implementations (value operations)
 * Ownership methods are intentionally excluded as different models implement them differently
 */
interface IMockImplementation {
    function owner() external view returns (address);

    /**
     * @notice Get the current stored value
     * @return The stored value
     */
    function value() external view returns (uint256);

    /**
     * @notice Set the stored value
     * @param newValue The new value to set
     */
    function setValue(uint256 newValue) external;

    // /**
    //  * @notice Setup function called after an upgrade
    //  * @param newValue The value to set after upgrade
    //  */
    // function postUpgradeSetup(uint256 newValue) external;

    /**
     * @notice Increment the stored value by 1
     * @dev Common across MockImplementationWithState and MockImplementationWithState_v2
     */
    function incrementValue() external;
}
