// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BaoOwnable_v2} from "@bao/BaoOwnable_v2.sol";
import {IMockImplementation, MockImplementationWithStateBase} from "../interfaces/IMockImplementation.sol";

/**
 * @title MockImplementationWithState_v2
 * @dev A mock implementation contract with state for testing upgrades
 */
contract MockImplementationWithState_v2 is Initializable, MockImplementationWithStateBase, BaoOwnable_v2 {
    function implementationType() external pure returns (uint256) {
        return uint(IMockImplementation.ImplementationType.MockImplementationWithState_v2);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner_) BaoOwnable_v2(owner_, 0) {
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
        // here all we can do is check that the owner is already set!
        // this is because the owner is in the implementation contract, not the proxy and we're
        // in the contesxt of the proxy
        // require(owner() == newOwner, "Owner mismatch after upgrade");
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function owner() public view virtual override(BaoOwnable_v2, IMockImplementation) returns (address owner_) {
        owner_ = BaoOwnable_v2.owner();
    }

    function setValue(uint256 newValue) external onlyOwner {
        _setValue(newValue);
    }

    function incrementValue() external onlyOwner {
        _incrementValue();
    }
}
