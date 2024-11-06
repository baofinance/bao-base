// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";

/// @notice Simple single owner authorization mixin layered on solady's Ownable.
/// @author rootminus0x1 based one interface from Solady (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
///

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
