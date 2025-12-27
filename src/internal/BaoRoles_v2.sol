// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC165} from "@bao/ERC165.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoCheckOwner_v2} from "@bao/internal/BaoCheckOwner_v2.sol";
import {BaoRolesCore} from "@bao/internal/BaoRolesCore.sol";

/// @title Bao Ownable
/// @author rootminus0x1 a barefaced copy of Solady's OwnableRoles contract
/// (https://github.com/vectorized/solady/blob/main/src/auth/OwnableRoles.sol)
/// @notice It is a copy of Solady's 'OwnableRoles' with the necessary 'Ownable' part
/// moved into a base contract 'BaoCheckOwner_v2'. We retain solady's sleek mechanism of
/// utilising the same seed slot for ownability and user roles.
/// This change allows it to be mixed in with the 'BaoOwnable' or 'BaoOwnableTransferrable'
/// contracts to create Roles enabled versions of those contracts
/// it also adds IRC165 interface query support
// solhint-disable-next-line contract-name-capwords
abstract contract BaoRoles_v2 is BaoCheckOwner_v2, BaoRolesCore {
    function _isOwner(address user) internal view virtual override returns (bool) {
        return user == _owner();
    }
}
