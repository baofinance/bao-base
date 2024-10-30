// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";
import { Ownable } from "@solady/auth/OwnableRoles.sol";

import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { BaoOwnable } from "@bao/BaoOwnable.sol";

/// @title Bao Ownable
/// @notice A thin layer over Solady's OwnableRoles that constrains the use of one-step ownership transfers
/// to be the same as `BaoOwnable`
/// it also adds IRC165 interface query support
/// @author rootminus0x1
abstract contract BaoOwnableRoles is OwnableRoles, BaoOwnable {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaoOwnable
    function _initializeOwner(address owner) internal virtual override(Ownable, BaoOwnable) {
        BaoOwnable._initializeOwner(owner);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(BaoOwnable) returns (bool) {
        return interfaceId == type(IOwnableRoles).interfaceId || BaoOwnable.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaoOwnable
    function transferOwnership(address newOwner) public payable virtual override(Ownable, BaoOwnable) {
        BaoOwnable.transferOwnership(newOwner);
    }

    function requestOwnershipHandover() public payable virtual override(Ownable, BaoOwnable) {
        BaoOwnable.requestOwnershipHandover();
    }

    function completeOwnershipHandover(address pendingOwner) public payable virtual override(Ownable, BaoOwnable) {
        BaoOwnable.completeOwnershipHandover(pendingOwner);
    }

    function renounceOwnership() public payable virtual override(Ownable, BaoOwnable) {
        BaoOwnable.renounceOwnership();
    }
    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaoOwnable
    function _setOwner(address newOwner) internal virtual override(Ownable, BaoOwnable) {
        BaoOwnable._setOwner(newOwner);
    }

    /// @inheritdoc BaoOwnable
    function _checkOwner() internal view virtual override(Ownable, BaoOwnable) {
        BaoOwnable._checkOwner();
    }

    /// @inheritdoc BaoOwnable
    function _ownershipHandoverValidFor() internal view virtual override(Ownable, BaoOwnable) returns (uint64) {
        return BaoOwnable._ownershipHandoverValidFor();
    }

    modifier onlyOwner() override(Ownable, BaoOwnable) {
        BaoOwnable._checkOwner();
        _;
    }
}
