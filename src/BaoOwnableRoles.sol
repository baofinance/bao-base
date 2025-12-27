// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {BaoRoles} from "@bao/internal/BaoRoles.sol";
import {BaoRolesCore} from "@bao/internal/BaoRolesCore.sol";

/// @title Bao Ownable Roles
/// see BaoOwnable and BaoRoles for more information
abstract contract BaoOwnableRoles is BaoOwnable, BaoRoles {
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnable, BaoRolesCore) returns (bool) {
        return BaoOwnable.supportsInterface(interfaceId) || BaoRolesCore.supportsInterface(interfaceId);
    }
}
