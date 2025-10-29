// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title MockUpgradeable
 * @notice UUPS upgradeable contracts for testing proxy deployments
 * @dev Centralized location for upgradeable test contracts
 */

// Simple counter for proxy testing
contract CounterV1 is Initializable, UUPSUpgradeable {
    uint256 public value;

    function initialize(uint256 _value) external initializer {
        value = _value;
    }

    function increment() external {
        value++;
    }

    function _authorizeUpgrade(address) internal override {}

    /// @dev Add missing upgradeTo method as wrapper around upgradeToAndCall
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}

// Oracle implementation for testing
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

// Complex Minter with multiple dependencies
contract MinterV1 is Initializable, UUPSUpgradeable, BaoOwnable {
    address public collateralToken;
    address public outputToken;
    address public oracle;

    function initialize(
        address _collateralToken,
        address _outputToken,
        address _oracle,
        address _owner
    ) external initializer {
        collateralToken = _collateralToken;
        outputToken = _outputToken;
        oracle = _oracle;
        _initializeOwner(_owner);
    }

    function mint(uint256 /* amount */) external view onlyOwner {
        // Mock minting logic
    }

    /// @dev Alias for outputToken to match test expectations
    function peggedToken() external view returns (address) {
        return outputToken;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @dev Add missing upgradeTo method as wrapper around upgradeToAndCall
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}

// Generic upgradeable contract for testing
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
