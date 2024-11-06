// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";

/// @notice Simple single owner authorization mixin layered on solady's Ownable but with a 3-step transfer
/// @author rootminus0x1 based one interface from Solady (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
/// It has 1-step ownership transfer support for deployer to final owner
/// No other 1-step ownership transfers are supported.
/// 3-step transfers are supported:
/// 1) initiateTransfer(address pendingOwner), called by the currentOwner
/// 2) validateTransfer(), called by the pending Owner to validate the address
/// 3) transferOwnership(address confirmPendingOwner), called by the currentOwner
/// The above sequence must happen in order
/// In addition there are timing constraints:
/// * step 2 (validate) must be called within 2 days of step 1 (initiate)
/// * step 3 (transfer) must be called between 2 and 4 days from step 1 (initiate)
/// Renunciation, which is simply a transfer to the zero address, is the same - sequence and timing - except
/// that there is no step 2 (validate) as the zero address cannot be validated in this way.
/// It cannot be initialised more than once.

interface IBaoOwnableTransferrable is IBaoOwnable {
    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev An ownership transfer to `pendingOwner` has been initiated.
    event OwnershipTransferInitiated(address indexed pendingOwner);

    /// @dev The ownership transfer to `pendingOwner` has been canceled.
    event OwnershipTransferCanceled(address indexed pendingOwner);

    /// @dev The ownership transfer to `pendingOwner` has been validated by `pendingOwner`.
    event OwnershipTransferValidated(address indexed pendingOwner);

    /*//////////////////////////////////////////////////////////////////////////
                             PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Request a two-step ownership transfer to the caller.
    /// The request will automatically expire in 48 hours (172800 seconds) by default.
    function initiateOwnershipTransfer(address toOwner) external payable;

    /// @dev Cancels the two-step ownership transfer to the caller, if any.
    function cancelOwnershipTransfer() external payable;

    function validateOwnershipTransfer() external payable;

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Returns the pending owner for the current two/three-step ownership transfer.
    /// both returned values will be zero if there is no current transfer.
    /// @param pendingOwner_ The new owner if the transfer process completes successfully
    function pendingOwner() external view returns (address pendingOwner_);

    /// @dev Returns the the expiry timestamp for the current two/three-step ownership transfer.
    /// both returned values will be zero if there is no current transfer.
    /// @param expiry The timestamp when the transfer will expire.
    function pendingExpiry() external view returns (uint64 expiry);

    /// @dev Returns the the expiry timestamp for the current validation or renunciation pause for the two/three-step ownership transfer.
    /// @param validateExpiryOrPause The expiry timestamp for validateing a transfer or when the pause ends if address is 0
    function pendingValidateExpiryOrPause() external view returns (uint64 validateExpiryOrPause);

    /// @dev Returns whether the pendingOwner address has been validated, address(0) is always validated
    /// @param validated Whether the transfer has been validated by the 'pendingOwner', or the 'pendingOwner' is address 0
    function pendingValidated() external view returns (bool validated);
}
