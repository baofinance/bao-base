// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {HarborRoles} from "@bao/internal/HarborRoles.sol";
import {HarborRolesCore} from "@bao/internal/HarborRolesCore.sol";

/// @title Harbor Ownable Roles
/// see HarborOwnable and HarborRoles for more information
abstract contract HarborOwnableRoles is HarborOwnable, HarborRoles {
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(HarborOwnable, HarborRolesCore) returns (bool) {
        return HarborOwnable.supportsInterface(interfaceId) || HarborRolesCore.supportsInterface(interfaceId);
    }
}
