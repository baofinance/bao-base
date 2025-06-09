// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable_v2} from "@bao/BaoOwnable_v2.sol";

/**
 * @title MockImplementation
 * @dev A simple mock implementation contract for testing upgrades
 */
contract MockImplementation_v2 is Initializable, UUPSUpgradeable, BaoOwnable_v2 {
    uint256 private _value;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner_) BaoOwnable_v2(owner_, 0) {
        _disableInitializers();
    }

    /**
     * @dev Initialize function - only used for first deployment
     * This follows the Initializable Contract Pattern
     */
    function initialize(uint256 initialValue) external initializer {
        __UUPSUpgradeable_init();
        _value = initialValue;
    }

    /**
     * @dev Function to set values post-upgrade without requiring re-initialization
     * This follows the Proxy State Preservation Pattern
     */
    function postUpgradeSetup(uint256 initialValue) external onlyOwner {
        _value = initialValue;
    }

    function value() external view returns (uint256) {
        return _value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        _value = newValue;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
