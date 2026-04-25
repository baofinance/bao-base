// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {HarborFixedOwnable} from "@bao/HarborFixedOwnable.sol";
import {IMockImplementation, MockImplementationWithStateBase} from "@bao-test/interfaces/IMockImplementation.sol";

/**
 * @title MockImplementationWithState_Fixed
 * @dev A mock implementation using HarborFixedOwnable for testing upgrades.
 *
 * Key difference from other mock implementations:
 * - Ownership is fixed at construction time via immutables
 * - No msg.sender dependency - owner is explicit constructor parameter
 * - Works correctly when deployed via factory (owner is not factory)
 * - Still supports UUPS upgrades (owner can upgrade)
 * - If delayedOwner is address(0), upgrades become impossible after delay
 */
contract MockImplementationWithState_Fixed is Initializable, MockImplementationWithStateBase, HarborFixedOwnable {
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationHarborFixedOwnable);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) HarborFixedOwnable(beforeOwner, delayedOwner, delay) {
        _disableInitializers();
    }

    // See https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable for initializer
    function initialize(uint256 initialValue) external initializer {
        __UUPSUpgradeable_init();
        _getStateStorage().value = initialValue;
    }

    /// @dev Function to set values post-upgrade without requiring re-initialization
    /// This follows the Proxy State Preservation Pattern
    // See https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable for reinitializer
    // after the initial deployment the version is 1, so the next one must be >1, e.g. 2 ↓
    function postUpgradeSetup(address /* newOwner */, uint256 newValue) external reinitializer(2) {
        StateStorage storage $ = _getStateStorage();
        emit ValueChanged($.value, newValue);
        $.value = newValue;
        // Owner is baked into the implementation - we can only verify it matches expectations
        // This is fundamentally different from slot-based ownership models
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function owner() public view virtual override(HarborFixedOwnable, IMockImplementation) returns (address owner_) {
        owner_ = HarborFixedOwnable.owner();
    }

    function setValue(uint256 newValue) external onlyOwner {
        _setValue(newValue);
    }

    function incrementValue() external onlyOwner {
        _incrementValue();
    }
}
