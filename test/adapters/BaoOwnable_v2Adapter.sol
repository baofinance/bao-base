// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

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
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationWithState_v2);
    }

    function name() external pure returns (string memory) {
        return "BaoOwnable_v2";
    }

    function deployImplementation(address prank, address initialOwner) external returns (address implementation) {
        vm.startPrank(prank);
        implementation = address(new MockImplementationWithState_v2(initialOwner));
        assertEq(MockImplementationWithState_v2(implementation).implementationType(), this.implementationType());
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
        return IBaoOwnable_v2.Unauthorized.selector;
    }
}
