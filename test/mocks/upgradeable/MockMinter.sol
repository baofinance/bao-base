// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

/**
 * @title MockMinter
 * @notice Complex Minter with multiple dependencies
 */
contract MockMinter is Initializable, UUPSUpgradeable, BaoOwnableRoles {
    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_TOKEN; // this is the wrapped token
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LEVERAGED_TOKEN;

    address public oracle;

    constructor(address _wrappedCollateralToken, address _peggedToken, address _leveragedToken) {
        require(_wrappedCollateralToken != address(0), "MockMinter: zero wrapped collateral");
        require(_peggedToken != address(0), "MockMinter: zero pegged token");
        require(_leveragedToken != address(0), "MockMinter: zero leveraged token");
        WRAPPED_COLLATERAL_TOKEN = _wrappedCollateralToken;
        PEGGED_TOKEN = _peggedToken;
        LEVERAGED_TOKEN = _leveragedToken;
    }

    function initialize(address _oracle, address _owner) external initializer {
        oracle = _oracle;
        _initializeOwner(_owner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @dev Add missing upgradeTo method as wrapper around upgradeToAndCall
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}
