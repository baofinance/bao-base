// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title MockImplementationWithState
 * @dev A mock implementation contract with state for testing upgrades
 */
contract MockImplementationWithState is Initializable, UUPSUpgradeable, BaoOwnable {
    // EIP-7201: Storage struct and slot
    struct MockImplementationWithStateStorage {
        uint256 value;
    }

    // keccak256("bao.mockimplementationwithstate.storage") - 1
    bytes32 private constant MOCKIMPLEMENTATIONWITHSTATE_STORAGE_SLOT =
        0x6e1b6c6e2e20e671e7e55ce49963cf343577b6c7d429f775d390d05f9b0a7b1b;

    // EIP-7201: Storage accessor (Proxy Pattern: EIP-7201)
    function _getMockImplementationWithStateStorage()
        private
        pure
        returns (MockImplementationWithStateStorage storage $)
    {
        assembly {
            $.slot := MOCKIMPLEMENTATIONWITHSTATE_STORAGE_SLOT
        }
    }

    // Events
    event ValueChanged(uint256 oldValue, uint256 newValue);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 initialValue) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        _getMockImplementationWithStateStorage().value = initialValue;
    }

    function value() external view returns (uint256) {
        return _getMockImplementationWithStateStorage().value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        MockImplementationWithStateStorage storage $ = _getMockImplementationWithStateStorage();
        emit ValueChanged($.value, newValue);
        $.value = newValue;
    }

    function incrementValue() external onlyOwner {
        _getMockImplementationWithStateStorage().value += 1;
    }

    /**
     * @dev Function to set values post-upgrade without requiring re-initialization
     * This follows the Proxy State Preservation Pattern
     */
    function postUpgradeSetup(uint256 newValue) external onlyOwner {
        MockImplementationWithStateStorage storage $ = _getMockImplementationWithStateStorage();
        emit ValueChanged($.value, newValue);
        $.value = newValue;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
