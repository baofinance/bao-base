// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

/// @notice Simple single owner authorization mixin layered on solady's Ownable.
/// @author rootminus0x1 based one interface from Solady (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
///

interface IBaoOwnable {
    /*//////////////////////////////////////////////////////////////////////////
                                   CUSTOM ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    // TODO: check which errors are actually thrown
    /// @dev The caller is not authorized to call the function.
    error Unauthorized();

    /// @dev Cannot double-initialize.
    error AlreadyInitialized();

    /// @dev Can only carry out actions within a window of time and if the new ower has validated.
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

    /// @notice Set the address of the new owner of the contract
    /// This is the final step in the 3-step-with-timeouts transfer approach
    /// @dev Set confirmOwner to address(0) to renounce any ownership.
    /// @param confirmOwner The address of the new owner of the contract.
    /// @dev Allows the owner to complete the two-step ownership transfer to `pendingOwner`.
    /// Reverts if there is no existing ownership transfer requested by `pendingOwner`.
    function transferOwnership(address confirmOwner) external payable;

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the address of the owner
    /// @return The address of the owner.
    function owner() external view returns (address);
}
