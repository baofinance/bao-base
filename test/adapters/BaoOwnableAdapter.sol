// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";

import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol";
import {MockImplementationWithState} from "test/mocks/MockImplementationWithState.sol";
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

/**
 * @title BaoOwnableAdapter
 * @notice Adapter for BaoOwnable ownership model
 * @dev Adapter Pattern: Provides access to implementation rather than mirroring its interface
 */
contract BaoOwnableAdapter is IOwnershipModel, Test {
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationWithState);
    }

    function name() external pure returns (string memory) {
        return "BaoOwnable";
    }

    function deployImplementation(address prank, address /*initialOwner*/) external returns (address implementation) {
        vm.startPrank(prank);
        implementation = address(new MockImplementationWithState());
        assertEq(MockImplementationWithState(implementation).implementationType(), this.implementationType());
        vm.stopPrank();
    }

    function deployProxy(
        address prank,
        address implementation,
        address initialOwner,
        uint256 initialValue
    ) external returns (address proxy) {
        vm.startPrank(prank);
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeWithSelector(MockImplementationWithState.initialize.selector, initialOwner, initialValue)
        );
        MockImplementationWithState(proxy).transferOwnership(initialOwner);
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
        UnsafeUpgrades.upgradeProxy(
            proxy,
            implementation,
            abi.encodeWithSelector(MockImplementationWithState.postUpgradeSetup.selector, newOwner, newValue)
        );
        vm.stopPrank();
    }

    function upgrade(address prank, address proxy, address implementation) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(proxy, implementation, "");
        vm.stopPrank();
    }

    function unauthorizedSelector() external pure returns (bytes4) {
        return IBaoOwnable.Unauthorized.selector;
    }
}
