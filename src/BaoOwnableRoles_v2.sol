// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaoOwnable_v2} from "@bao/BaoOwnable_v2.sol";
import {BaoRoles_v2} from "@bao/internal/BaoRoles_v2.sol";

/// @title Bao Ownable Roles
/// see BaoOwnable_v2 and BaoRoles_v2 for more information
abstract contract BaoOwnableRoles_v2 is BaoOwnable_v2, BaoRoles_v2 {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/
    constructor(address owner) BaoOwnable_v2(owner) {}
    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnable_v2, BaoRoles_v2) returns (bool) {
        return BaoOwnable_v2.supportsInterface(interfaceId) || BaoRoles_v2.supportsInterface(interfaceId);
    }
}
