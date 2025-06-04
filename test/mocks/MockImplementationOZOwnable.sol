// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IMockImplementation, MockImplementationWithStateBase} from "../interfaces/IMockImplementation.sol";

/**
 * @title MockImplementationOZOwnable
 * @dev A mock implementation using OZ OwnableUpgradeable instead of BaoOwnable
 */
contract MockImplementationOZOwnable is Initializable, MockImplementationWithStateBase, OwnableUpgradeable {
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationOZOwnable);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // See https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable for initializer
    function initialize(address owner_, uint256 initialValue) external initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _getStateStorage().value = initialValue;
    }

    /// @dev Function to set values post-upgrade without requiring re-initialization
    /// This follows the Proxy State Preservation Pattern
    // See https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable for reinitializer
    // after the initial deployment the version is 1, so the next one must be >1, e.g. 2 ↓
    function postUpgradeSetup(address newOwner, uint256 newValue) external reinitializer(2) {
        _getStateStorage().value = newValue;
        address oldOwner = owner();
        if (newOwner != oldOwner) {
            _transferOwnership(newOwner);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function owner() public view virtual override(OwnableUpgradeable, IMockImplementation) returns (address owner_) {
        owner_ = OwnableUpgradeable.owner();
    }

    function setValue(uint256 newValue) external onlyOwner {
        _setValue(newValue);
    }

    function incrementValue() external onlyOwner {
        _incrementValue();
    }
}
