// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IMockImplementation, MockImplementationWithStateBase} from "../interfaces/IMockImplementation.sol";

import {console2} from "forge-std/console2.sol";

/**
 * @title MockImplementationWithState
 * @dev A mock implementation contract with state for testing upgrades
 */
contract MockImplementationWithState is Initializable, MockImplementationWithStateBase, BaoOwnable {
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationWithState);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // See https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable for initializer
    function initialize(address owner_, uint256 initialValue) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        _getStateStorage().value = initialValue;
        _getStateStorage().stableValue = initialValue;
    }

    /// @dev Function to set values post-upgrade without requiring re-initialization
    /// This follows the Proxy State Preservation Pattern
    // See https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable for reinitializer
    // after the initial deployment the version is 1, so the next one must be >1, e.g. 2 ↓
    function postUpgradeSetup(address newOwner, uint256 newValue) external reinitializer(2) {
        StateStorage storage $ = _getStateStorage();
        emit ValueChanged($.value, newValue);
        $.value = newValue;
        address oldOwner = owner();
        if (newOwner != oldOwner) {
            _setOwner(oldOwner, newOwner);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function owner() public view virtual override(BaoOwnable, IMockImplementation) returns (address owner_) {
        owner_ = BaoOwnable.owner();
    }

    function setValue(uint256 newValue) external onlyOwner {
        _setValue(newValue);
    }

    function incrementValue() external onlyOwner {
        _incrementValue();
    }
}
