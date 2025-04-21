// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOwnershipModel, IOwnershipModelFactory} from "../interfaces/IOwnershipModel.sol";
import {MockImplementationWithState_v2} from "../mocks/MockImplementationWithState_v2.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title BaoOwnableV2Adapter
 * @notice Adapter for BaoOwnable_v2 ownership model
 * @dev Adapter Pattern: Wraps MockImplementationWithState_v2 to conform to IOwnershipModel interface
 */
contract BaoOwnableV2Adapter is IOwnershipModel, Test {
    // The contract being adapted
    MockImplementationWithState_v2 private _implementation;

    /**
     * @notice Create a new adapter pointing to a specific implementation
     * @param implementation The implementation to adapt
     */
    constructor(address implementation) {
        _implementation = MockImplementationWithState_v2(implementation);
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
     * @dev BaoOwnable_v2 doesn't support this directly, it's automatic
     */
    function transferOwnership(address /*newOwner*/) external pure {
        // BaoOwnable_v2 doesn't have transferOwnership
        revert("BaoOwnable_v2 doesn't support manual ownership transfer");
    }

    /**
     * @notice Complete ownership setup (wait for transfer in BaoOwnable_v2)
     * @dev For BaoOwnable_v2, we need to wait for the delay period
     */
    function completeOwnershipSetup() external {
        // For BaoOwnable_v2, ownership transfers after delay
        // Skip ahead in time to complete the transfer
        vm.warp(block.timestamp + 3600); // Skip 1 hour (the delay in BaoOwnable_v2)
    }

    /**
     * @notice Get initialization data for BaoOwnable_v2
     * @param value The initial value
     */
    function getInitializationData(address /*owner*/, uint256 value) external pure returns (bytes memory) {
        return abi.encodeWithSelector(MockImplementationWithState_v2.initialize.selector, value);
    }

    /**
     * @notice Get post-upgrade setup data
     * @param value The value to set after upgrade
     */
    function getPostUpgradeSetupData(uint256 value) external pure returns (bytes memory) {
        return abi.encodeWithSelector(MockImplementationWithState_v2.postUpgradeSetup.selector, value);
    }
}

/**
 * @title BaoOwnableV2AdapterFactory
 * @notice Factory for creating BaoOwnableV2Adapter instances
 * @dev Factory Pattern: Creates and configures adapters
 */
contract BaoOwnableV2AdapterFactory is IOwnershipModelFactory, Test {
    /**
     * @notice Create a new BaoOwnable_v2 model instance
     * @param finalOwner The address that should eventually own the contract
     */
    function createModel(address finalOwner) external returns (IOwnershipModel) {
        MockImplementationWithState_v2 impl = new MockImplementationWithState_v2(finalOwner);
        return new BaoOwnableV2Adapter(address(impl));
    }

    /**
     * @notice Attach adapter to an existing proxy
     * @param proxyAddress The address of the proxy
     */
    function attachToProxy(address proxyAddress) external returns (IOwnershipModel) {
        return new BaoOwnableV2Adapter(proxyAddress);
    }

    /**
     * @notice BaoOwnable_v2 does not support manual ownership transfer
     */
    function supportsOwnershipTransfer() external pure returns (bool) {
        return false;
    }

    /**
     * @notice Get expected owner after upgrade from Stem
     */
    function getExpectedOwnerAfterUpgrade(
        address /*emergencyOwner*/,
        address /*finalOwner*/
    ) external view returns (address) {
        // For BaoOwnable_v2, the test contract becomes the owner after upgrade
        return address(this);
    }

    /**
     * @notice Get expected owner after direct upgrade
     */
    function getExpectedOwnerAfterDirectUpgrade(address /*originalOwner*/) external view returns (address) {
        // For BaoOwnable_v2, the test contract becomes the owner after direct upgrade
        return address(this);
    }

    /**
     * @notice Get expected owner after recovery
     */
    function getExpectedOwnerAfterRecovery(address /*emergencyOwner*/) external view returns (address) {
        // For BaoOwnable_v2, the test contract becomes the owner after recovery
        return address(this);
    }
}
