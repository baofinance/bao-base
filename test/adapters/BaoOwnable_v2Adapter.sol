// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test, console2} from "forge-std/Test.sol";

import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol";
import {MockImplementationWithState_v2} from "test/mocks/MockImplementationWithState_v2.sol";
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol";
import {IBaoOwnable_v2} from "@bao/interfaces/IBaoOwnable_v2.sol";

/**
 * @title BaoOwnableAdapter
 * @notice Adapter for BaoOwnable ownership model
 * @dev Adapter Pattern: Provides access to implementation rather than mirroring its interface
 */
contract BaoOwnable_v2Adapter is IOwnershipModel, Test {
    function deployImplementation(address prank, address initialOwner) external returns (address implementation) {
        vm.startPrank(prank);
        implementation = address(new MockImplementationWithState_v2(initialOwner));
        vm.stopPrank();
        skip(3600);
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
            abi.encodeWithSelector(MockImplementationWithState_v2.initialize.selector, initialValue)
        );
        vm.stopPrank();
    }

    function upgrade(address prank, address proxy, address implementation, uint256 newValue) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(
            proxy,
            implementation,
            abi.encodeWithSelector(MockImplementationWithState_v2.postUpgradeSetup.selector, newValue)
        );
        vm.stopPrank();
    }

    function upgrade(address prank, address proxy, address implementation) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(proxy, implementation, "");
        vm.stopPrank();
    }

    function unauthorizedSelector() external pure returns (bytes4) {
        return IBaoOwnable_v2.Unauthorized.selector;
    }
}
