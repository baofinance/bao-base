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

    function initialize(uint256 _price, address _owner) external initializer {
        price = _price;
        _initializeOwner(_owner);
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
