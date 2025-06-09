// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title MockImplementationWithImmutables
 * @dev A mock implementation contract with immutable values for testing upgrades
 */
contract MockImplementationWithImmutables is Initializable, UUPSUpgradeable, BaoOwnable {
    // Immutable value set in constructor
    uint256 public immutable immutableValue;
    uint256 private _stateValue;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 immutableValue_) {
        _disableInitializers();
        immutableValue = immutableValue_;
    }

    // Add overload with owner parameter
    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // Add the missing stateValue function
    function stateValue() external view returns (uint256) {
        return _stateValue;
    }

    // Add a function to set the state value during initialization/upgrade
    function setStateValue(uint256 value) external {
        _stateValue = value;
    }
}
