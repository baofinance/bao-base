// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// import { console2 } from "forge-std/console2.sol";

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { BaoOwnable } from "@bao/BaoOwnable.sol";
import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";
import { IBaoOwnableTransferrable } from "@bao/interfaces/IBaoOwnableTransferrable.sol";

/// @title Bao Ownable
/// @dev Note:
/// This implementation auto-initialises the owner to `msg.sender`.
/// You MUST call the `_initializeOwner` in the constructor / initializer of the deriving contract.
/// This initialization sets the owner to `msg.sender`, not to the passed 'finalOwner' parameter.
///
/// This contract follows [EIP-173](https://eips.ethereum.org/EIPS/eip-173) for compatibility,
/// the nomenclature for the 3-step ownership transfer may be unique to this codebase.
/// the unique nomencalture has been extended to a three step transfer and a two step renunciation.
/// The three/two steps are:
/// * initiateOwnershipTransfer (passing address(0) here is a renunciation). This starts the transfer sequence.
///   This step starts a timer for the next two steps.
/// * validateOwnershipTransfer. This must be called by the address passed in the initiate step and within 2 days of
///   initiation. For renunciations (transfer to address(0)), this call cannot be made so is not needed - it is assumed
//    that address(0) is intended. For renunciation there is still a 2 day pause.
/// * transferOwnership. This completes the transfer and must be completed between 2 and 4 days after initiation.
///
/// Initialisation sets the owner to the caller, and also performs the first two steps of the above transfer to the passed
/// parameter. This allows the deployer to act as owner then transfer ownership with a single transferOwnership call.
///
/// No one step-transfers are allowed except in the unique one-shot transferOwnership after initializeOwnership.
/// This simplifies deploy scripts that must do owner type set-up but then can transfer to the real owner once done
///
/// Multiple initialisations are not allowed, to ensure this we make a separate check for a previously set owner including
/// including to address(0). This ensure that the initializeOwner, an otherwise unprotected function, cannot be called twice.
///
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
contract BaoOwnableTransferrable is IBaoOwnableTransferrable, BaoOwnable {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaoOwnable
    function _initializeOwner(address finalOwner) internal override(BaoOwnable) {
        unchecked {
            _checkNotInitialized();
            _setOwner(address(0), msg.sender);
            // set up a transferOwnership to finalOwner
            _setPending(
                finalOwner,
                uint64(block.timestamp), // no pause for completion
                true,
                3600 // you have 1 hour
            );
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(BaoOwnable) returns (bool) {
        return interfaceId == type(IBaoOwnableTransferrable).interfaceId || BaoOwnable.supportsInterface(interfaceId);
    }

    /// @inheritdoc IBaoOwnableTransferrable
    function pendingOwner() public view virtual returns (address pendingOwner_) {
        (pendingOwner_, , , ) = _pending();
    }

    /// @inheritdoc IBaoOwnableTransferrable
    function pendingExpiry() public view virtual returns (uint64 expiry) {
        (, , , expiry) = _pending();
    }

    /// @inheritdoc IBaoOwnableTransferrable
    function pendingValidateExpiryOrPause() public view virtual returns (uint64 validateExpiryOrPause) {
        (, validateExpiryOrPause, , ) = _pending();
    }

    /// @inheritdoc IBaoOwnableTransferrable
    function pendingValidated() public view virtual returns (bool validated) {
        (, , validated, ) = _pending();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice initiates transfer to a new owner or renunciation of ownership (i.e. transfer to address(0))
    /// starts an expiry for the target owner to validate, or in the case of renunciation, for a pause
    /// during that period up to the expiry, the transfer can be cancelled or validated
    /// The request will automatically expire in 4 days.
    function initiateOwnershipTransfer(address toAddress) public payable virtual {
        unchecked {
            _checkOwner();
            _setPending(
                toAddress,
                uint64(block.timestamp + _VALIDATE_EXPIRY_OR_PAUSE_PERIOD),
                toAddress == address(0),
                _EXPIRY_AFTER_PAUSE_PERIOD
            );
        }
    }

    /// @dev Cancels the two-step ownership transfer to the caller, if any.
    function cancelOwnershipTransfer() public payable virtual {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // only pending or owner
            //let pendingOwner := shr(96, shl(96, sload(_PENDING_SLOT)))
            let pendingOwner_ := and(sload(_PENDING_SLOT), 0xffffffffffffffffffffffffffffffffffffffff)
            if iszero(or(eq(caller(), pendingOwner_), eq(caller(), sload(_INITIALIZED_SLOT)))) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // clear the pending slot
            sstore(_PENDING_SLOT, 0)
            // Emit the {OwnershipTransferCanceled} event.
            log2(0, 0, _OWNERSHIP_TRANSFER_CANCELED_EVENT_SIGNATURE, pendingOwner_)
        }
    }

    /// @notice any transfer to a non-zero address needs to be validated
    /// to ensure that the transfer address is a working address
    /// if it is a renunciation then this function is not called
    function validateOwnershipTransfer() public payable virtual {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let pending_ := sload(_PENDING_SLOT)
            // onlyPendingOwner can call this, but only once - if validated already then it's a mistake
            // 95 represents the clearing of all the bits above the address excluding the validated bit
            // combining these checks in one reduces contract size and gas
            let pendingOwner_ := and(pending_, 0x1ffffffffffffffffffffffffffffffffffffffff)
            // let pendingOwner := shr(95, shl(95, pending_)) // owner address + validated bit => validateing twice is disallowed
            if or(
                // onlyPendingOwner can call this, but only once - if validated already then it's a mistake
                iszero(eq(caller(), pendingOwner_)),
                // only before half expiry
                gt(timestamp(), shr(192, pending_))
            ) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // set the validated  bit to indicate it has been validated
            sstore(_PENDING_SLOT, or(pending_, shl(_BIT_VALIDATED, 0x1)))
            // Emit the {OwnershipTransferInitiated} event.
            // although we left the validated bit in place above (via the shl 95) it isn't set if we got here
            log2(0, 0, _OWNERSHIP_TRANSFER_VALIDATED_EVENT_SIGNATURE, pendingOwner_)
        }
    }

    /// @notice Set the address of the new owner of the contract
    /// @dev Set confirmOwner to address(0) to renounce any ownership.
    /// @param confirmOwner The address of the new owner of the contract
    function transferOwnership(address confirmOwner) public payable virtual override(BaoOwnable, IBaoOwnable) {
        unchecked {
            address oldOwner;
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                oldOwner := sload(_INITIALIZED_SLOT)
                if iszero(eq(caller(), oldOwner)) {
                    mstore(0x00, 0x82b42900) // `Unauthorized()`.
                    revert(0x1c, 0x04)
                }
                let pending_ := sload(_PENDING_SLOT)
                let pause := shr(192, pending_)
                // only if the pending address has been validated and matches the stored address
                // and we haven't past expiry
                if or(
                    iszero(eq(or(confirmOwner, shl(_BIT_VALIDATED, 0x1)), shr(95, shl(95, pending_)))),
                    or(
                        // within the timescales allowed
                        gt(timestamp(), add(pause, shr(232, shl(64, pending_)))),
                        gt(pause, timestamp())
                    )
                ) {
                    mstore(0x00, 0x8cd65fff) // `CannotCompleteTransfer()`.
                    revert(0x1c, 0x04)
                }
                sstore(_PENDING_SLOT, 0)
            }
            _setOwner(oldOwner, confirmOwner);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PRIVATE DATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The pending owner slot is defined in BaoOwnable,
    /// where the bottom 160 bits are for the pending address and,
    /// the top 64 bits are for the expiry of the transfer (that gives half a trillion years)
    /// as we have two expiry periods in this implementation we reassign
    /// the first expiry period to the top 64 bits (renaming the old single expiry) and
    /// the next top 24 bits for a second expiry period delta (nearly 200 days).
    /// i.e. you add the first period expiry to the delta to get the second period expiry
    /// We also add an additional bit to indicate whether the validate function has been called.
    // | 255, 64 bits - validate expiry/end of pause timestamp | 191, 24 bits - completion delta | 160, 1 bit - validated | 159, 160 bits - pending owner address |
    // initialisation:
    //      validate expiry = now, completion delta = 1 hour, validated = true
    // transfer:
    //      validate expiry = now + 2 days, completion delta = 2 days, validated = false
    //      validated = true
    // renounce:
    //      validate expiry = now + 2 days, completion delta = 2 days, validated = true
    uint8 private constant _BIT_VALIDATED = 160;
    uint64 private constant _VALIDATE_EXPIRY_OR_PAUSE_PERIOD = 2 days;
    uint24 private constant _EXPIRY_AFTER_PAUSE_PERIOD = 2 days;

    /// @dev `keccak256(bytes("OwnershipTransferInitiated(address)"))`.
    uint256 private constant _OWNERSHIP_TRANSFER_INITIATED_EVENT_SIGNATURE =
        0x20f5afdf40bf7b43c89031a5d4369a30b159e512d164aa46124bcb706b4a1caf;
    /// @dev `keccak256(bytes("OwnershipTransferCanceled(address)"))`.
    uint256 private constant _OWNERSHIP_TRANSFER_CANCELED_EVENT_SIGNATURE =
        0x6ecd4842251bedd053b09547c0fabaab9ec98506ebf24469e8dd5560412ed37f;
    /// @dev `keccak256(bytes("OwnershipTransferValidated(address)"))`.
    uint256 private constant _OWNERSHIP_TRANSFER_VALIDATED_EVENT_SIGNATURE =
        0x5e45c45222c097812bf35207ea5f05aad99b929c4bb5654f9ac3217b6b7f9d98;
    /// @dev `keccak256(bytes("OwnershipTransferred(address,address)"))`.

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _pending()
        internal
        view
        virtual
        returns (address pendingOwner_, uint64 validateExpiryOrPause, bool validated, uint64 transferExpiry)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            pendingOwner_ := sload(_PENDING_SLOT)
            // extract the 64 bits that hold the first expiry
            validateExpiryOrPause := shr(192, pendingOwner_)
            // add the timeout offset 24 bits just below the above
            transferExpiry := add(validateExpiryOrPause, shr(232, shl(64, pendingOwner_)))
            // extract the validate flag at position 161 (from right), i.e. bottom bit of byte 11 (from left)
            validated := byte(11, pendingOwner_)
        }
    }

    function _setPending(address pendingOwner_, uint64 step2Expiry, bool validated, uint24 step3ExpiryDelta) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            sstore(
                _PENDING_SLOT,
                or(
                    or(or(pendingOwner_, shl(_BIT_VALIDATED, validated)), shl(192, step2Expiry)),
                    shl(168, step3ExpiryDelta)
                )
            )
            // Emit the {OwnershipTransferInitiated} event.
            log2(0, 0, _OWNERSHIP_TRANSFER_INITIATED_EVENT_SIGNATURE, pendingOwner_)
        }
    }
}
