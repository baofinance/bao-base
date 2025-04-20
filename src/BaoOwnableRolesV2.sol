// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaoOwnableV2} from "@bao/BaoOwnableV2.sol";
import {BaoRolesV2} from "@bao/internal/BaoRolesV2.sol";

/// @title Bao Ownable Roles
/// see BaoOwnableV2 and BaoRolesV2 for more information
abstract contract BaoOwnableRolesV2 is BaoOwnableV2, BaoRolesV2 {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/
    constructor(address owner) BaoOwnableV2(owner) {}
    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnableV2, BaoRolesV2) returns (bool) {
        return BaoOwnableV2.supportsInterface(interfaceId) || BaoRolesV2.supportsInterface(interfaceId);
    }
}
