// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol";
import {MockImplementationWithState_v2} from "test/mocks/MockImplementationWithState_v2.sol";
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol";
import {IBaoOwnable_v2} from "@bao/interfaces/IBaoOwnable_v2.sol";

/**
 * @title BaoOwnableAdapter
 * @notice Adapter for BaoOwnable ownership model
 * @dev Adapter Pattern: Provides access to implementation rather than mirroring its interface
 */
contract BaoOwnable_v2Adapter is IOwnershipModel {
    address private _proxy;
    MockImplementationWithState_v2 private _implementation;
    address private _owner;

    function deploy(address initialOwner, uint256 initialValue) external {
        _owner = initialOwner;
        _implementation = new MockImplementationWithState_v2(_owner);

        _proxy = UnsafeUpgrades.deployUUPSProxy(
            address(_implementation),
            abi.encodeWithSelector(MockImplementationWithState_v2.initialize.selector, initialValue)
        );
    }

    // this doesn't prank - that's the job of the test
    function upgrade(address newOwner, uint256 newValue) external {
        _owner = newOwner;
        _implementation = new MockImplementationWithState_v2(newOwner);

        UnsafeUpgrades.upgradeProxy(
            address(_proxy),
            address(_implementation),
            abi.encodeWithSelector(MockImplementationWithState_v2.postUpgradeSetup.selector, newValue)
        );
    }

    function implementation() external view returns (IMockImplementation) {
        return _implementation;
    }

    function proxy() external view returns (IMockImplementation) {
        return IMockImplementation(_proxy);
    }

    function unauthorizedSelector() external pure returns (bytes4) {
        return IBaoOwnable_v2.Unauthorized.selector;
    }
}
