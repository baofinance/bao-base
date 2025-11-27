// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title HarborKeys
 * @notice Key constants for Harbor protocol deployment
 * @dev Shared between production and dev deployments
 */
library HarborKeys {
    // Contract keys (top-level, no dots)
    string internal constant PEGGED = "pegged";
    string internal constant PEGGED_IMPLEMENTATION = "pegged__MintableBurnableERC20_v1";
    string internal constant PEGGED_IMPLEMENTATION_LABEL = "pegged.implementation";

    // Pegged token configuration keys
    string internal constant PEGGED_SYMBOL = "pegged.symbol";
    string internal constant PEGGED_NAME = "pegged.name";
    string internal constant PEGGED_OWNER = "pegged.owner";
}
