// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";

import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol";
import {MockImplementationWithState_Fixed} from "test/mocks/MockImplementationWithState_Fixed.sol";
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol";
import {IBaoFixedOwnable} from "@bao/interfaces/IBaoFixedOwnable.sol";

/**
 * @title BaoFixedOwnableAdapter
 * @notice Adapter for BaoFixedOwnable ownership model
 * @dev Adapter Pattern: Provides access to implementation rather than mirroring its interface
 *
 * Key differences from BaoOwnable_v2Adapter:
 * - Owner is explicit constructor parameter, not msg.sender
 * - No delay used for tests (immediate ownership)
 * - Works correctly when deployed via factory
 */
contract BaoFixedOwnableAdapter is IOwnershipModel, Test {
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationBaoFixedOwnable);
    }

    function name() external pure returns (string memory) {
        return "BaoFixedOwnable";
    }

    function deployImplementation(address prank, address initialOwner) external returns (address implementation) {
        vm.startPrank(prank);
        // BaoFixedOwnable: beforeOwner = initialOwner, delayedOwner = initialOwner, delay = 0
        // This means ownership is immediately and permanently initialOwner
        implementation = address(new MockImplementationWithState_Fixed(initialOwner, initialOwner, 0));
        assertEq(MockImplementationWithState_Fixed(implementation).implementationType(), this.implementationType());
        vm.stopPrank();
        // No skip needed - delay is 0
    }

    function deployProxy(
        address prank,
        address implementation,
        address /*initialOwner*/,
        uint256 initialValue
    ) external returns (address proxy) {
        vm.startPrank(prank);
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeWithSelector(MockImplementationWithState_Fixed.initialize.selector, initialValue)
        );
        vm.stopPrank();
    }

    function upgradeAndChangeStuff(
        address prank,
        address proxy,
        address implementation,
        address newOwner,
        uint256 newValue
    ) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(proxy, implementation, "");
        vm.stopPrank();
        vm.prank(newOwner);
        IMockImplementation(proxy).postUpgradeSetup(newOwner, newValue);
    }

    function upgrade(address prank, address proxy, address implementation) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(proxy, implementation, "");
        vm.stopPrank();
    }

    function unauthorizedSelector() external pure returns (bytes4) {
        return IBaoFixedOwnable.Unauthorized.selector;
    }
}
