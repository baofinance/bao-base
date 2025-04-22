// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Test, console2} from "forge-std/Test.sol";

import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol";
import {MockImplementationOZOwnable} from "test/mocks/MockImplementationOZOwnable.sol";
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol";

/**
 * @title OZOwnableAdapter
 * @notice Adapter for OZ's OwnableUpgradeable ownership model
 * @dev Adapter Pattern: Provides access to implementation rather than mirroring its interface
 */
contract OZOwnableAdapter is IOwnershipModel, Test {
    function deployImplementation(address prank, address /*initialOwner*/) external returns (address implementation) {
        vm.startPrank(prank);
        implementation = address(new MockImplementationOZOwnable());
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
            address(implementation),
            abi.encodeWithSelector(MockImplementationOZOwnable.initialize.selector, initialOwner, initialValue)
        );
        vm.stopPrank();
    }
    function upgrade(address prank, address proxy, address implementation, uint256 newValue) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(implementation),
            abi.encodeWithSelector(MockImplementationOZOwnable.postUpgradeSetup.selector, newValue)
        );
        vm.stopPrank();
    }

    function upgrade(address prank, address proxy, address implementation) external {
        vm.startPrank(prank);
        UnsafeUpgrades.upgradeProxy(proxy, implementation, "");
        vm.stopPrank();
    }

    function unauthorizedSelector() external pure returns (bytes4) {
        return OwnableUpgradeable.OwnableUnauthorizedAccount.selector;
    }
}
