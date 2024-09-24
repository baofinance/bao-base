// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable, OwnableRoles } from "@solady/auth/OwnableRoles.sol";
import { OwnableOverrides } from "./OwnableOverrides.sol";

/// @dev this is a thin layer over OwnableRoles changing some defaults
/// The function overrides should be identicle to BaoOwnable
abstract contract BaoOwnableRoles is OwnableRoles, OwnableOverrides {
    /// @inheritdoc OwnableOverrides
    function _initializeOwner(address newOwner) internal virtual override(Ownable, OwnableOverrides) {
        OwnableOverrides._initializeOwner(newOwner);
    }

    /// @notice prevent solady's Ownable re-initializing
    function _guardInitializeOwner() internal pure virtual override(Ownable, OwnableOverrides) returns (bool guard) {
        return OwnableOverrides._guardInitializeOwner();
    }
}
