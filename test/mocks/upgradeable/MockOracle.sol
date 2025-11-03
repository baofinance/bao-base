// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title OracleV1
 * @notice Oracle implementation for testing
 */
contract OracleV1 is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public price;

    /// @notice Initialize with two-step ownership
    /// @param _price Initial oracle price
    /// @param _finalOwner Final owner address (pending, requires transferOwnership to complete)
    /// @dev msg.sender becomes temporary owner for setup, _finalOwner becomes pending
    function initialize(uint256 _price, address _finalOwner) external initializer {
        price = _price;
        _initializeOwner(_finalOwner);
    }

    function setPrice(uint256 _price) external virtual onlyOwner {
        price = _price;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @dev Add missing upgradeTo method as wrapper around upgradeToAndCall
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}
