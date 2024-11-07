// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaoOwnable } from "@bao/BaoOwnable.sol";
import { BaoRoles } from "@bao/internal/BaoRoles.sol";

/// @title Bao Ownable Roles
/// see BaoOwnable and BaoRoles for more information
contract BaoOwnableRoles is BaoOwnable, BaoRoles {
    function supportsInterface(bytes4 interfaceId) public view virtual override(BaoOwnable, BaoRoles) returns (bool) {
        return BaoOwnable.supportsInterface(interfaceId) || BaoRoles.supportsInterface(interfaceId);
    }
}
