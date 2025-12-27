// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFixedOwnable} from "@bao/BaoFixedOwnable.sol";
import {BaoRolesCore} from "@bao/internal/BaoRolesCore.sol";

/// @title Bao Fixed Ownable Roles
/// @notice Roles implementation layered on top of BaoFixedOwnable.
/// @dev See BaoFixedOwnable and BaoRolesCore for more information.
abstract contract BaoFixedOwnableRoles is BaoFixedOwnable, BaoRolesCore {
    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) BaoFixedOwnable(beforeOwner, delayedOwner, delay) {}

    function _isOwner(address user) internal view virtual override returns (bool) {
        return user == _owner();
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoFixedOwnable, BaoRolesCore) returns (bool) {
        return BaoFixedOwnable.supportsInterface(interfaceId) || BaoRolesCore.supportsInterface(interfaceId);
    }
}
