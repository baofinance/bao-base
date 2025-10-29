// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title MockUpgradeableContract
 * @notice Generic upgradeable contract for testing
 * @dev Does not use BaoOwnable - demonstrates older pattern
 */
contract MockUpgradeableContract is Initializable, UUPSUpgradeable {
    uint256 public value;
    string public name;
    address public owner;

    function initialize(uint256 _value, string memory _name, address _owner) external initializer {
        value = _value;
        name = _name;
        owner = _owner;
    }

    function setValue(uint256 _value) external {
        require(msg.sender == owner, "Not owner");
        value = _value;
    }

    function setName(string memory _name) external {
        require(msg.sender == owner, "Not owner");
        name = _name;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == owner, "Not owner");
    }
}
