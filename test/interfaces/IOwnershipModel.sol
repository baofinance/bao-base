// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOwnershipModel
 * @notice Interface for ownership model adapters
 * @dev Strategy Pattern: Defines common interface for all ownership models
 */
interface IOwnershipModel {
    /**
     * @notice Get the value stored in the contract
     * @return The stored value
     */
    function getValue() external view returns (uint256);

    /**
     * @notice Set the value in the contract
     * @param newValue The new value to store
     */
    function setValue(uint256 newValue) external;

    /**
     * @notice Get the current owner of the contract
     * @return The address of the current owner
     */
    function getOwner() external view returns (address);

    /**
     * @notice Transfer ownership to a new address
     * @param newOwner The address to transfer ownership to
     */
    function transferOwnership(address newOwner) external;

    /**
     * @notice Complete setup of ownership (if needed by the model)
     * @dev This is a no-op for models that don't require additional setup
     */
    function completeOwnershipSetup() external;

    /**
     * @notice Get initialization data for this model
     * @param owner The initial owner
     * @param value The initial value
     * @return The encoded initialization data
     */
    function getInitializationData(address owner, uint256 value) external pure returns (bytes memory);

    /**
     * @notice Get data for post-upgrade setup
     * @param value The value to set after upgrade
     * @return The encoded setup data
     */
    function getPostUpgradeSetupData(uint256 value) external pure returns (bytes memory);
}

/**
 * @title IOwnershipModelFactory
 * @notice Factory interface for creating ownership model adapters
 * @dev Factory Pattern: Used to create and attach adapters
 */
interface IOwnershipModelFactory {
    /**
     * @notice Create a new instance of this ownership model
     * @param finalOwner The address that should eventually own the contract
     * @return A new ownership model instance
     */
    function createModel(address finalOwner) external returns (IOwnershipModel);

    /**
     * @notice Attach adapter to an existing proxy
     * @param proxyAddress The address of the proxy
     * @return An ownership model adapter connected to the proxy
     */
    function attachToProxy(address proxyAddress) external returns (IOwnershipModel);

    /**
     * @notice Determine if this model supports ownership transfer
     * @return True if the model supports ownership transfer, false otherwise
     */
    function supportsOwnershipTransfer() external pure returns (bool);

    /**
     * @notice Get the expected owner after upgrading from Stem
     * @param emergencyOwner The emergency owner from Stem
     * @param finalOwner The intended final owner
     * @return The address that will be the owner after upgrade
     */
    function getExpectedOwnerAfterUpgrade(address emergencyOwner, address finalOwner) external view returns (address);

    /**
     * @notice Get the expected owner after direct upgrade (not via Stem)
     * @param originalOwner The owner before upgrade
     * @return The address that will be the owner after upgrade
     */
    function getExpectedOwnerAfterDirectUpgrade(address originalOwner) external view returns (address);

    /**
     * @notice Get the expected owner after emergency recovery
     * @param emergencyOwner The emergency owner from Stem
     * @return The address that will be the owner after recovery
     */
    function getExpectedOwnerAfterRecovery(address emergencyOwner) external view returns (address);
}
