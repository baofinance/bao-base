// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IMockImplementation} from "../interfaces/IMockImplementation.sol";

/**
 * @title MockImplementationOZOwnable
 * @dev A mock implementation using OZ OwnableUpgradeable instead of BaoOwnable
 */
contract MockImplementationOZOwnable is Initializable, UUPSUpgradeable, OwnableUpgradeable, IMockImplementation {
    // EIP-7201: Storage struct and slot
    struct MockImplementationOZOwnableStorage {
        uint256 value;
    }

    // keccak256("bao.mockimplementationownableupgradeable.storage") - 1
    bytes32 private constant MOCKIMPLEMENTATIONOWNABLEUPGRADEABLE_STORAGE_SLOT =
        0x9d7955a625105381a23cd83039436890e06a206d930ea14b10a284d4cd0549f9;

    // EIP-7201: Storage accessor (Proxy Pattern: EIP-7201)
    function _getOwnableUpgradeableStorage() private pure returns (MockImplementationOZOwnableStorage storage $) {
        assembly {
            $.slot := MOCKIMPLEMENTATIONOWNABLEUPGRADEABLE_STORAGE_SLOT
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 initialValue) external initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _getOwnableUpgradeableStorage().value = initialValue;
    }

    function value() external view returns (uint256) {
        return _getOwnableUpgradeableStorage().value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        _getOwnableUpgradeableStorage().value = newValue;
    }

    /**
     * @dev Function to set values post-upgrade without requiring re-initialization
     * This follows the Proxy State Preservation Pattern
     */
    function postUpgradeSetup(uint256 newValue) external onlyOwner {
        _getOwnableUpgradeableStorage().value = newValue;
    }

    /**
     * @dev Implementing the incrementValue function required by the interface
     */
    function incrementValue() external onlyOwner {
        _getOwnableUpgradeableStorage().value += 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function owner() public view virtual override(OwnableUpgradeable, IMockImplementation) returns (address owner_) {
        owner_ = OwnableUpgradeable.owner();
    }
}
