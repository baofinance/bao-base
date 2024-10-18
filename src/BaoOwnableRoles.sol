// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";
import { Ownable } from "@solady/auth/OwnableRoles.sol";

import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { BaoOwnable } from "@bao/BaoOwnable.sol";

/// @title Bao Ownable
/// @notice A thin layer over Solady's OwnableRoles that constrains the use of one-step ownership transfers
/// it also adds IRC165 interface query support
/// @author rootminus0x1
abstract contract BaoOwnableRoles is OwnableRoles, BaoOwnable {
    /// @dev Override to return true to make `_initializeOwner` prevent double-initialization.
    /// This could happen, for example, in normal function call and not just in the initializer
    function _guardInitializeOwner() internal pure virtual override(Ownable, BaoOwnable) returns (bool guard) {
        return BaoOwnable._guardInitializeOwner();
    }

    /// @notice initialise the UUPS proxy
    function _initializeOwner(address owner) internal virtual override(Ownable, BaoOwnable) {
        BaoOwnable._initializeOwner(owner);
    }

    function transferOwnership(address newOwner) public payable virtual override(Ownable, BaoOwnable) {
        BaoOwnable.transferOwnership(newOwner);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(BaoOwnable) returns (bool) {
        return interfaceId == type(IOwnableRoles).interfaceId || BaoOwnable.supportsInterface(interfaceId);
    }
}
