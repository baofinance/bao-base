// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import { IERC5313 } from "@openzeppelin/contracts/interfaces/IERC5313.sol";

/// @notice Simple single owner authorization mixin layered on solady's Ownable.
/// @author rootminus0x1 based one interface from Solady (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
///
/// @dev Note:
/// This implementation does NOT auto-initialize the owner to `msg.sender`.
/// You MUST call the `_initializeOwner` in the constructor / initializer.
///
/// While the ownable portion follows
/// [EIP-173](https://eips.ethereum.org/EIPS/eip-173) for compatibility,
/// the nomenclature for the 2-step ownership handover may be unique to this codebase.
/// the unique nomencalture has been extended to a two step renunciation.
/// in addition to the 2-step ownership timeout, there is also a pause period:
/// * requestOwnershipTransfer/Renunciation
/// * half the expiry period, where no completion is allowed. canceling is allowed
/// * completeOwnershipTransfer/Renunciation must be completed before exiry (as before)
///
/// multiple initialisations are not allowed
///
/// all 1-step transfers or renunciations are disallowed, except in onec scenario:
/// as part of a deployement if the owner parameter of _initialize is also the caller's address then
/// the caller/owner gets to do exactly one 1-step transfer/renounceOwnership.

interface IBaoOwnable is IERC5313 {
    /*//////////////////////////////////////////////////////////////
                             CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev The caller is not authorized to call the function.
    error Unauthorized();

    /// @dev The `newOwner` cannot be the zero address.
    error NewOwnerIsZeroAddress();

    /// @dev The `pendingOwner` does not have a valid handover request.
    error NoHandoverRequest();

    /// @dev Cannot double-initialize.
    error AlreadyInitialized();

    /// @dev Can only carry out actions within a window of time.
    error CannotCompleteYet();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The ownership is transferred from `oldOwner` to `newOwner`.
    /// This event is intentionally kept the same as OpenZeppelin's Ownable to be
    /// compatible with indexers and [EIP-173](https://eips.ethereum.org/EIPS/eip-173),
    /// despite it not being as lightweight as a single argument event.
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    /// @dev An ownership handover to `pendingOwner` has been requested.
    event OwnershipHandoverRequested(address indexed pendingOwner);

    /// @dev The ownership handover to `pendingOwner` has been canceled.
    event OwnershipHandoverCanceled(address indexed pendingOwner);

    /*//////////////////////////////////////////////////////////////
                       PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Allows the owner to transfer the ownership to `newOwner`.
    function transferOwnership(address newOwner) external payable;

    /// @dev Allows the owner to renounce their ownership.
    function renounceOwnership() external payable;

    /// @dev Request a two-step ownership handover to the caller.
    /// The request will automatically expire in 48 hours (172800 seconds) by default.
    function requestOwnershipHandover() external payable;

    /// @dev Cancels the two-step ownership handover to the caller, if any.
    function cancelOwnershipHandover() external payable;

    /// @dev Allows the owner to complete the two-step ownership handover to `pendingOwner`.
    /// Reverts if there is no existing ownership handover requested by `pendingOwner`.
    function completeOwnershipHandover(address pendingOwner) external payable;

    /// @dev Request a two-step ownership renunciation.
    /// The request will automatically expire in 4 days by default.
    function requestOwnershipRenunciation() external payable;

    /// @dev Cancels the two-step ownership handover to the caller, if any.
    function cancelOwnershipRenunciation() external payable;

    /// @dev Allows the owner to complete the two-step ownership renunciation.
    /// Reverts if there is no existing ownership renunciation requested by the owner.
    function completeOwnershipRenunciation() external payable;

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the expiry timestamp for the two-step ownership handover to `pendingOwner`.
    function ownershipHandoverExpiresAt(address pendingOwner) external view returns (uint256 result);
}