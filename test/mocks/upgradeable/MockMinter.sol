// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

/**
 * @title MockMinter
 * @notice Complex Minter with multiple dependencies
 * @dev Demonstrates design pattern: constructor for immutable/rarely-changed values, initialize for frequently-updated values
 */
contract MockMinter is Initializable, UUPSUpgradeable, BaoOwnableRoles {
    // These variables are set in the constructor, not the initializer, to minimize contract size and gas usage.
    // Constructor parameters are for things that should not change or won't change often (require proxy upgrade to modify).
    // Initialize parameters are for things we may want to change frequently (have update functions for these).
    // We prefer constructor parameters because they don't consume contract code size.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_TOKEN; // this is the wrapped token
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LEVERAGED_TOKEN;

    address public oracle;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _wrappedCollateralToken, address _peggedToken, address _leveragedToken) {
        require(_wrappedCollateralToken != address(0), "MockMinter: zero wrapped collateral");
        require(_peggedToken != address(0), "MockMinter: zero pegged token");
        require(_leveragedToken != address(0), "MockMinter: zero leveraged token");
        WRAPPED_COLLATERAL_TOKEN = _wrappedCollateralToken;
        PEGGED_TOKEN = _peggedToken;
        LEVERAGED_TOKEN = _leveragedToken;
    }

    /// @notice Initialize the minter with oracle and owner
    /// @dev When deployed via CREATE3 proxy, msg.sender is the CREATE3 intermediary.
    ///      Uses two-step ownership: _finalOwner set as deployer (temporary), _finalOwner as pending.
    function initialize(address _oracle, address _finalOwner) external initializer {
        oracle = _oracle;
        _initializeOwner(_finalOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @dev Add missing upgradeTo method as wrapper around upgradeToAndCall
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}
