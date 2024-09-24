// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// TODO: incorporate OZ UUPSUpgradeable

import { Ownable } from "@solady/auth/Ownable.sol";

/// @dev this is a thin layer over Ownable changing some defaults
abstract contract BaoOwnable is Ownable {
    /// @dev extra check for zero address
    function _initializeOwner(address newOwner) internal virtual override(Ownable) {
        if (newOwner == address(0)) {
            revert NewOwnerIsZeroAddress();
        }
        Ownable._initializeOwner(newOwner);
    }

    /// @notice prevent solady's Ownable re-initializing
    function _guardInitializeOwner() internal pure virtual override(Ownable) returns (bool guard) {
        guard = true;
    }
}
