// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title MockImplementationOZOwnable
 * @dev A mock implementation using OZ OwnableUpgradeable instead of BaoOwnable
 */
contract MockImplementationOZOwnableNotInitializer is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // EIP-7201: Storage struct and slot
    struct MockImplementationStorage {
        uint256 value;
        bool initialized;
    }

    // keccak256("bao.mockimplementationownableupgradeablenotinitializer.storage") - 1
    bytes32 private constant MOCKIMPLEMENTATION_STORAGE_SLOT =
        0x48897bdcbc0e91b54494365ef99ebd7eed1bf55944e2956d16cb55e524bd2043;

    // EIP-7201: Storage accessor (Proxy Pattern: EIP-7201)
    function _getMockImplementationStorage() private pure returns (MockImplementationStorage storage $) {
        assembly {
            $.slot := MOCKIMPLEMENTATION_STORAGE_SLOT
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 initialValue) external {
        // This is intentionally not using initializer modifier to allow reinitializing for testing
        MockImplementationStorage storage $ = _getMockImplementationStorage();
        require(!$.initialized, "Already initialized");
        $.initialized = true;
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        $.value = initialValue;
    }

    function value() external view returns (uint256) {
        return _getMockImplementationStorage().value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        _getMockImplementationStorage().value = newValue;
    }

    /**
     * @dev Function to set values post-upgrade without requiring re-initialization
     * This follows the Proxy State Preservation Pattern
     */
    function postUpgradeSetup(uint256 newValue) external onlyOwner {
        _getMockImplementationStorage().value = newValue;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
