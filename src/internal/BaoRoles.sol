// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC165} from "@bao/ERC165.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoCheckOwner} from "@bao/internal/BaoCheckOwner.sol";
import {BaoRolesCore} from "@bao/internal/BaoRolesCore.sol";

/// @title Bao Ownable
/// @author rootminus0x1 a barefaced copy of Solady's OwnableRoles contract
/// (https://github.com/vectorized/solady/blob/main/src/auth/OwnableRoles.sol)
/// @notice It is a copy of Solady's 'OwnableRoles' with the necessary 'Ownable' part
/// moved into a base contract 'BaoCheckOwner'. We retain solady's sleek mechanism of
/// utilising the same seed slot for ownability and user roles.
/// This change allows it to be mixed in with the 'BaoOwnable' or 'BaoOwnableTransferrable'
/// contracts to create Roles enabled versions of those contracts
/// it also adds IRC165 interface query support
abstract contract BaoRoles is BaoCheckOwner, BaoRolesCore {
    function _isOwner(address user) internal view virtual override returns (bool isOwner) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            isOwner := eq(user, sload(_INITIALIZED_SLOT))
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

}
