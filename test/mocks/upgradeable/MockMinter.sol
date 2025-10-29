// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title MinterV1
 * @notice Complex Minter with multiple dependencies
 */
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
