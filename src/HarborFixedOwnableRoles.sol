// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborFixedOwnable} from "@bao/HarborFixedOwnable.sol";
import {HarborRolesCore} from "@bao/internal/HarborRolesCore.sol";

/// @title Harbor Fixed Ownable Roles
/// @notice Roles implementation layered on top of HarborFixedOwnable.
/// @dev See HarborFixedOwnable and HarborRolesCore for more information.
abstract contract HarborFixedOwnableRoles is HarborFixedOwnable, HarborRolesCore {
    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) HarborFixedOwnable(beforeOwner, delayedOwner, delay) {}

    function _isOwner(address user) internal view virtual override returns (bool) {
        return user == _owner();
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(HarborFixedOwnable, HarborRolesCore) returns (bool) {
        return HarborFixedOwnable.supportsInterface(interfaceId) || HarborRolesCore.supportsInterface(interfaceId);
    }
}
