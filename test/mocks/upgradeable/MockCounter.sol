// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title CounterV1
 * @notice Simple counter for proxy testing
 */
contract CounterV1 is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    /// @notice Initialize with two-step ownership
    /// @param _value Initial counter value
    /// @param _finalOwner Final owner address (pending, requires transferOwnership to complete)
    /// @dev msg.sender becomes temporary owner for setup, _finalOwner becomes pending
    function initialize(uint256 _value, address _finalOwner) external initializer {
        value = _value;
        _initializeOwner(_finalOwner);
    }

    function increment() external {
        value++;
    }

    function transferOwnership(address confirmOwner) public override(BaoOwnable) {
        if (msg.sender != owner()) revert Unauthorized();

        unchecked {
            assembly {
                sstore(_PENDING_SLOT, or(confirmOwner, shl(192, add(timestamp(), 3600))))
            }
        }

        super.transferOwnership(confirmOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @dev Add missing upgradeTo method as wrapper around upgradeToAndCall
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}
