// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title MockUpgradeableContract
 * @notice Generic upgradeable contract for testing with BaoOwnable
 */
contract MockUpgradeableContract is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;
    string public name;

    function initialize(uint256 _value, string memory _name, address _owner) external initializer {
        value = _value;
        name = _name;
        _initializeOwner(_owner);
    }

    function setValue(uint256 _value) external {
        if (msg.sender != owner()) revert Unauthorized();
        value = _value;
    }

    function setName(string memory _name) external {
        if (msg.sender != owner()) revert Unauthorized();
        name = _name;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != owner()) revert Unauthorized();
    }
}
