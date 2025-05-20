// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

/// @notice Simple single owner authorization mixin based on Solady's Ownable
/// @author rootminus0x1 based on Solady's (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
/// No ownership transfers are supported.

// solhint-disable-next-line contract-name-capwords
interface IBaoOwnable_v2 {
    /*//////////////////////////////////////////////////////////////////////////
                                   CUSTOM ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The caller is not authorized to call the function.
    error Unauthorized();

    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The ownership is transferred from `previousOwner` to `newOwner`.
    /// This event is intentionally kept the same as OpenZeppelin's Ownable to be
    /// compatible with indexers and [EIP-173](https://eips.ethereum.org/EIPS/eip-173),
    /// despite it not being as lightweight as a single argument event.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the address of the owner
    /// @return The address of the owner.
    function owner() external view returns (address);
}
