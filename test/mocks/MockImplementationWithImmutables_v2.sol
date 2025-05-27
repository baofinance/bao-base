// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable_v2} from "@bao/BaoOwnable_v2.sol";

/**
 * @title MockImplementationV1WithImmutables
 * @dev A mock implementation contract with immutable values for testing upgrades
 */
contract MockImplementationV1WithImmutables_v2 is Initializable, UUPSUpgradeable, BaoOwnable_v2 {
    // Immutable value set in constructor
    uint256 public immutable immutableValue;

    // State variable that can change
    uint256 private _stateValue;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner_, uint256 immutableValue_) BaoOwnable_v2(owner_, 0) {
        _disableInitializers();
        immutableValue = immutableValue_;
    }

    // Add overload with owner parameter
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function stateValue() external view returns (uint256) {
        return _stateValue;
    }

    function setStateValue(uint256 newValue) external onlyOwner {
        _stateValue = newValue;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
