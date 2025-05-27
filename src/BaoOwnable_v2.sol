// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaoCheckOwner_v2} from "@bao/internal/BaoCheckOwner_v2.sol";
import {ERC165} from "@bao/ERC165.sol";
import {IBaoOwnable_v2} from "@bao/interfaces/IBaoOwnable_v2.sol";

/// @title Bao Ownable
/// @dev Note:
/// This implementation auto-initialises the owner to `msg.sender`.
/// Initialisation is done completely in the constructor, initialising an immutable owner
///
/// BaoOwnable enforces a one-time transfer from the initial deployer to the pending owner
/// This transfer occurs automatically exactly (or within a few seconds, of) 1 hour after deployment
/// Once transferred, ownership cannot be transferred again through BaoOwnable's mechanism
///
/// This initialization sets the owner to `msg.sender`, not to the passed 'finalOwner' parameter.
/// The contract deployer can now act as owner within a 1 hour time period.
///
/// This contract follows [IERC5313] for ownership query
/// There is also  a nod and a wink toward [EIP-173](https://eips.ethereum.org/EIPS/eip-173) for compatibility,
//  however there is no transferOwnership function.
///
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
// solhint-disable-next-line contract-name-capwords
abstract contract BaoOwnable_v2 is IBaoOwnable_v2, BaoCheckOwner_v2, ERC165 {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Initialises the ownership
    /// This is an unprotected function designed to let a derive contract's initializer to call it
    /// This function can only be called once.
    /// The caller of the initializer function will be the deployer of the contract. The deployer (msg.sender)
    /// becomes the owner, allowing them to do owner-type set up, then ownership is transferred to the 'finalOwner'
    /// when 'transferOwnership' is called. 'transferOwnership' must be called within an hour.
    /// @param finalOwner sets the owner, a privileged address, of the contract to be set when 'transferOwnership' is called
    // slither-disable-next-line dead-code
    constructor(address finalOwner, uint256 delay) BaoCheckOwner_v2(finalOwner, delay) {}

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // @inheritdoc IBaoOwnable
    function owner() public view virtual returns (address owner_) {
        owner_ = _owner();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        // base class doesn't support any interfaces
        return interfaceId == type(IBaoOwnable_v2).interfaceId || super.supportsInterface(interfaceId);
    }
}
