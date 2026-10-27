// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

/// @notice Simple single owner authorization mixin based on Solady's Ownable
/// @author rootminus0x1 based on Solady's (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
/// It has ownership transfer support for deployer to final owner
/// No other ownership transfers are supported.

interface IHarborOwnable is IERC5313 {
    /*//////////////////////////////////////////////////////////////////////////
                                   CUSTOM ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The caller is not authorized to call the function.
    error Unauthorized();

    /// @dev Cannot double-initialize.
    error AlreadyInitialized();

    /// @dev Nothing is pending, or `confirmOwner` is not the pending owner announced at initialisation.
    error CannotCompleteTransfer();

    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The ownership is transferred from `previousOwner` to `newOwner`.
    /// This event is intentionally kept the same as OpenZeppelin's Ownable to be
    /// compatible with indexers and [EIP-173](https://eips.ethereum.org/EIPS/eip-173),
    /// despite it not being as lightweight as a single argument event.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////////////////
                             PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Bring the hand-over to the pending owner announced at initialisation forward to now, as the owner.
    /// @dev After the hand-over's time it has taken effect already and nothing changes. Ownership hands over by
    /// itself an hour after initialisation whether or not this is called.
    /// @param confirmOwner The pending owner.
    function transferOwnership(address confirmOwner) external;

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the address of the owner
    /// @return The address of the owner.
    function owner() external view returns (address);
}
