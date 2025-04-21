// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOwnershipModel, IOwnershipModelFactory} from "../interfaces/IOwnershipModel.sol";
import {MockImplementationWithState} from "../mocks/MockImplementationWithState.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title BaoOwnableAdapter
 * @notice Adapter for BaoOwnable ownership model
 * @dev Adapter Pattern: Wraps MockImplementationWithState to conform to IOwnershipModel interface
 */
contract BaoOwnableAdapter is IOwnershipModel {
    // The contract being adapted
    MockImplementationWithState private _implementation;

    /**
     * @notice Create a new adapter pointing to a specific implementation
     * @param implementation The implementation to adapt
     */
    constructor(address implementation) {
        _implementation = MockImplementationWithState(implementation);
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
     * @notice Complete ownership setup (no-op for BaoOwnable as it's immediate)
     */
    function completeOwnershipSetup() external {
        // For BaoOwnable, ownership is set in initialization or transferOwnership
        // No additional steps required
    }

    /**
     * @notice Get initialization data for BaoOwnable
     * @param owner The initial owner
     * @param value The initial value
     */
    function getInitializationData(address owner, uint256 value) external pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                MockImplementationWithState.initialize.selector,
                owner, // This is the pending owner for BaoOwnable
                value
            );
    }

    /**
     * @notice Get post-upgrade setup data
     * @param value The value to set after upgrade
     */
    function getPostUpgradeSetupData(uint256 value) external pure returns (bytes memory) {
        return abi.encodeWithSelector(MockImplementationWithState.postUpgradeSetup.selector, value);
    }
}

/**
 * @title BaoOwnableAdapterFactory
 * @notice Factory for creating BaoOwnableAdapter instances
 * @dev Factory Pattern: Creates and configures adapters
 */
contract BaoOwnableAdapterFactory is IOwnershipModelFactory, Test {
    /**
     * @notice Create a new BaoOwnable model instance
     */
    function createModel(address /*finalOwner*/) external returns (IOwnershipModel) {
        MockImplementationWithState impl = new MockImplementationWithState();
        return new BaoOwnableAdapter(address(impl));
    }

    /**
     * @notice Attach adapter to an existing proxy
     * @param proxyAddress The address of the proxy
     */
    function attachToProxy(address proxyAddress) external returns (IOwnershipModel) {
        return new BaoOwnableAdapter(proxyAddress);
    }

    /**
     * @notice BaoOwnable supports ownership transfer
     */
    function supportsOwnershipTransfer() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Get expected owner after upgrade from Stem
     */
    function getExpectedOwnerAfterUpgrade(
        address /*emergencyOwner*/,
        address /*finalOwner*/
    ) external view returns (address) {
        // For BaoOwnable, the test contract becomes the owner after upgrade,
        // not emergencyOwner nor finalOwner
        return address(this);
    }

    /**
     * @notice Get expected owner after direct upgrade
     */
    function getExpectedOwnerAfterDirectUpgrade(address /*originalOwner*/) external view returns (address) {
        // For BaoOwnable, the test contract becomes the owner after direct upgrade
        return address(this);
    }

    /**
     * @notice Get expected owner after recovery
     */
    function getExpectedOwnerAfterRecovery(address /*emergencyOwner*/) external view returns (address) {
        // For BaoOwnable, the test contract becomes the owner after recovery
        return address(this);
    }
}
