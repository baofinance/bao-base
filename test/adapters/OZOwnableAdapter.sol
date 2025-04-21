// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOwnershipModel, IOwnershipModelFactory} from "../interfaces/IOwnershipModel.sol";
import {MockImplementationOwnableUpgradeable} from "../mocks/MockImplementationOwnableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title OZOwnableAdapter
 * @notice Adapter for OpenZeppelin Ownable ownership model
 * @dev Adapter Pattern: Wraps MockImplementationOwnableUpgradeable to conform to IOwnershipModel interface
 */
contract OZOwnableAdapter is IOwnershipModel {
    // The contract being adapted
    MockImplementationOwnableUpgradeable private _implementation;

    /**
     * @notice Create a new adapter pointing to a specific implementation
     * @param implementation The implementation to adapt
     */
    constructor(address implementation) {
        _implementation = MockImplementationOwnableUpgradeable(implementation);
    }

    /**
     * @notice Get the value from the implementation
     */
    function getValue() external view returns (uint256) {
        return _implementation.value();
    }

    /**
     * @notice Set the value in the implementation
     * @param newValue The new value to set
     */
    function setValue(uint256 newValue) external {
        _implementation.setValue(newValue);
    }

    /**
     * @notice Get the owner from the implementation
     */
    function getOwner() external view returns (address) {
        return _implementation.owner();
    }

    /**
     * @notice Transfer ownership in the implementation
     * @param newOwner The new owner to set
     */
    function transferOwnership(address newOwner) external {
        _implementation.transferOwnership(newOwner);
    }

    /**
     * @notice Complete ownership setup (no-op for OZ Ownable)
     */
    function completeOwnershipSetup() external {
        // For OZ Ownable, ownership is set in initialization
        // No additional steps required
    }

    /**
     * @notice Get initialization data for OZ Ownable
     * @param owner The initial owner
     * @param value The initial value
     */
    function getInitializationData(address owner, uint256 value) external pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                MockImplementationOwnableUpgradeable.initialize.selector,
                owner, // This is the direct owner for OZ Ownable
                value
            );
    }

    /**
     * @notice Get post-upgrade setup data
     * @param value The value to set after upgrade
     */
    function getPostUpgradeSetupData(uint256 value) external pure returns (bytes memory) {
        return abi.encodeWithSelector(MockImplementationOwnableUpgradeable.postUpgradeSetup.selector, value);
    }
}

/**
 * @title OZOwnableAdapterFactory
 * @notice Factory for creating OZOwnableAdapter instances
 * @dev Factory Pattern: Creates and configures adapters
 */
contract OZOwnableAdapterFactory is IOwnershipModelFactory, Test {
    /**
     * @notice Create a new OZ Ownable model instance
     */
    function createModel(address /*finalOwner*/) external returns (IOwnershipModel) {
        MockImplementationOwnableUpgradeable impl = new MockImplementationOwnableUpgradeable();
        return new OZOwnableAdapter(address(impl));
    }

    /**
     * @notice Attach adapter to an existing proxy
     * @param proxyAddress The address of the proxy
     */
    function attachToProxy(address proxyAddress) external returns (IOwnershipModel) {
        return new OZOwnableAdapter(proxyAddress);
    }

    /**
     * @notice OZ Ownable supports ownership transfer
     */
    function supportsOwnershipTransfer() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Get expected owner after upgrade from Stem
     */
    function getExpectedOwnerAfterUpgrade(
        address emergencyOwner,
        address /*finalOwner*/
    ) external pure returns (address) {
        // For OZ Ownable, emergencyOwner becomes the owner after upgrade
        return emergencyOwner;
    }

    /**
     * @notice Get expected owner after direct upgrade
     */
    function getExpectedOwnerAfterDirectUpgrade(address originalOwner) external pure returns (address) {
        // For OZ Ownable, original owner remains the owner after direct upgrade
        return originalOwner;
    }

    /**
     * @notice Get expected owner after recovery
     */
    function getExpectedOwnerAfterRecovery(address emergencyOwner) external pure returns (address) {
        // For OZ Ownable, emergency owner becomes the owner after recovery
        return emergencyOwner;
    }
}
