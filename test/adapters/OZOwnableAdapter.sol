// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol";
import {MockImplementationOZOwnable} from "test/mocks/MockImplementationOZOwnable.sol";
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol";

/**
 * @title OZOwnableAdapter
 * @notice Adapter for OZ's OwnableUpgradeable ownership model
 * @dev Adapter Pattern: Provides access to implementation rather than mirroring its interface
 */
contract OZOwnableAdapter is IOwnershipModel {
    address private _proxy;
    MockImplementationOZOwnable private _implementation;
    address private _owner;

    function deploy(address initialOwner, uint256 initialValue) external {
        _owner = initialOwner;
        _implementation = new MockImplementationOZOwnable();

        _proxy = UnsafeUpgrades.deployUUPSProxy(
            address(_implementation),
            abi.encodeWithSelector(MockImplementationOZOwnable.initialize.selector, initialOwner, initialValue)
        );
    }

    // this doesn't prank - that's the job of the test
    function upgrade(address newOwner, uint256 newValue) external {
        _owner = newOwner;
        _implementation = new MockImplementationOZOwnable();

        UnsafeUpgrades.upgradeProxy(
            address(_proxy),
            address(_implementation),
            abi.encodeWithSelector(MockImplementationOZOwnable.postUpgradeSetup.selector, newValue)
        );
    }

    function implementation() external view returns (IMockImplementation) {
        return _implementation;
    }

    function proxy() external view returns (IMockImplementation) {
        return IMockImplementation(_proxy);
    }

    function unauthorizedSelector() external pure returns (bytes4) {
        return OwnableUpgradeable.OwnableUnauthorizedAccount.selector;
    }
}
