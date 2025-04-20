// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable__v2} from "@bao/BaoOwnable__v2.sol";

/**
 * @title MockImplementationWithState
 * @dev A mock implementation contract with state for testing upgrades
 */
contract MockImplementationWithState__v2 is Initializable, UUPSUpgradeable, BaoOwnable__v2 {
    // Storage
    uint256 private _value;

    // Events
    event ValueChanged(uint256 oldValue, uint256 newValue);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 initialValue) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        _value = initialValue;
    }

    function value() external view returns (uint256) {
        return _value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        emit ValueChanged(_value, newValue);
        _value = newValue;
    }

    function incrementValue() external onlyOwner {
        _value += 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
