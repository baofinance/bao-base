// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// TODO: incorporate OZ UUPSUpgradeable

import {Ownable, OwnableRoles} from "@solady/auth/OwnableRoles.sol";
import {BaoOwnable} from "src/BaoOwnable.sol";

/// @dev this is a thin layer over Ownable changing some defaults
abstract contract BaoOwnableRoles is BaoOwnable, OwnableRoles {

    /// @dev extra check for zero address
    function _initializeOwner(address newOwner) internal override(BaoOwnable, Ownable) {
        BaoOwnable._initializeOwner(newOwner);
    }

    /// @notice prevent solady's Ownable re-initializing
    function _guardInitializeOwner() internal pure override(BaoOwnable, Ownable) returns (bool guard) {
        BaoOwnable._guardInitializeOwner();
    }

}
