// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoOwnableTransferrable} from "@bao/BaoOwnableTransferrable.sol";
import {BaoRoles} from "@bao/internal/BaoRoles.sol";

/// @title Bao Ownable Transferrable Roles
/// see BaoOwnableTransferrable and BaoRoles for more information
abstract contract BaoOwnableTransferrableRoles is BaoOwnableTransferrable, BaoRoles {
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnableTransferrable, BaoRoles) returns (bool) {
        return BaoOwnableTransferrable.supportsInterface(interfaceId) || BaoRoles.supportsInterface(interfaceId);
    }
}
