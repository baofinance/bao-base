// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// TODO: incorporate OZ UUPSUpgradeable

import { Ownable } from "@solady/auth/Ownable.sol";
import { OwnableOverrides } from "./OwnableOverrides.sol";

/// @dev this is a thin layer over Ownable changing some defaults
/// The function overrides should be identicle to BaoOwnableRoles
abstract contract BaoOwnable is Ownable, OwnableOverrides {
    /// @inheritdoc OwnableOverrides
    function _initializeOwner(address newOwner) internal virtual override(Ownable, OwnableOverrides) {
        OwnableOverrides._initializeOwner(newOwner);
    }

    /// @notice prevent solady's Ownable re-initializing
    function _guardInitializeOwner() internal pure virtual override(Ownable, OwnableOverrides) returns (bool guard) {
        return OwnableOverrides._guardInitializeOwner();
    }
}
