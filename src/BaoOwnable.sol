// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// import { console2 } from "forge-std/console2.sol";

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";

/// @title Bao Ownable
/// @dev Note:
/// This implementation does NOT auto-initialize the owner to `msg.sender`.
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
abstract contract BaoOwnable is IBaoOwnable, IERC165 {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice initialise the UUPS proxy
    /// @param finalOwner sets the owner, a privileged address, of the contract to be set when 'transferOwnership' is called
    function _initializeOwner(address finalOwner) internal virtual {
        assembly ("memory-safe") {
            // this is an unprotected function so only let the deployer call it, and then only once
            // use transferOwner for deployers to call to finalise the owner, and then
            // also only once and if they set the owner to themselves here
            if sload(_INITIALIZED_SLOT) {
                mstore(0x00, 0x0dc149f0) // `AlreadyInitialized()`.
                revert(0x1c, 0x04)
            }
        }
        unchecked {
            _setOwner(address(0), msg.sender);
            // set up a transferOwnership to finalOwner
            _setPending(
                finalOwner,
                0, // no pause for completion
                true,
                3600 // you have 1 hour
            );
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IBaoOwnable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Get the address of the owner
    /// @return owner_ The address of the owner.
    function owner() public view virtual returns (address owner_) {
        assembly ("memory-safe") {
            owner_ := sload(_INITIALIZED_SLOT)
        }
    }

    /// @inheritdoc IBaoOwnable
    function pending()
        public
        view
        virtual
        returns (address pendingOwner, uint64 acceptExpiryOrCompletePause, bool accepted, uint64 handoverExpiry)
    {
        // bytes32 accepted32;
        assembly ("memory-safe") {
            pendingOwner := sload(_PENDING_SLOT)
            // extract the 64 bits that hold the first expiry
            acceptExpiryOrCompletePause := shr(192, pendingOwner)
            handoverExpiry := add(acceptExpiryOrCompletePause, shr(232, shl(64, pendingOwner)))
            //accepted32 := byte(11, pendingOwner)
            accepted := byte(11, pendingOwner)
        }
        // console2.log("accepted:");
        // console2.logBytes32(accepted32);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice initiates handover to a new owner or renunciation of ownership (i.e. handover to address(0))
    /// starts an expiry for the target owner to accept, or in the case of renunciation, for a pause
    /// during that period up to the expiry, the handover can be cancelled or accepted
    /// The request will automatically expire in 4 days.
    function initiateOwnershipHandover(address toAddress) public payable virtual {
        unchecked {
            _checkOwner(); // wake-disable-line unchecked-return-value
            _setPending(toAddress, 2 days, toAddress == address(0), 2 days);
        }
    }

    /// @dev Cancels the two-step ownership handover to the caller, if any.
    function cancelOwnershipHandover() public payable virtual {
        assembly ("memory-safe") {
            let pending_ := sload(_PENDING_SLOT)
            if iszero(pending_) {
                mstore(0x00, 0xc80a10b4) // `NoHandoverInitiated()`.
                revert(0x1c, 0x04)
            }
            // only pending or owner
            let owner_ := sload(_INITIALIZED_SLOT)
            let pendingOwner := shr(96, shl(96, pending_))
            let caller_ := caller()
            if iszero(or(eq(caller_, pendingOwner), eq(caller_, owner_))) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // clear the pending slot
            sstore(_PENDING_SLOT, 0)
            // Emit the {OwnershipHandoverCanceled} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_CANCELED_EVENT_SIGNATURE, pendingOwner)
        }
    }

    /// @notice any handover to a non-zero address needs to be accepted
    /// to ensure that the handover address is a working address
    /// if it is a renunciation then this function is not called
    function acceptOwnershipHandover() public payable virtual {
        // bytes32 stored;
        assembly ("memory-safe") {
            let pending_ := sload(_PENDING_SLOT)
            // onlyPendingOwner can call this, but only once - if accepted already then it's a mistake
            // // 95 represents the bits above the address and accepted bit
            let pendingOwner := shr(95, shl(95, pending_)) // owner address + accepted bit => accepting twice is disallowed
            if or(
                // onlyPendingOwner can call this, but only once - if accepted already then it's a mistake
                iszero(eq(caller(), pendingOwner)),
                // only before half expiry
                gt(timestamp(), shr(192, pending_))
            ) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // set the accepted  bit to indicate it has been accepted
            // stored := or(pending_, shl(_BIT_ACCEPTED, 0x1))
            sstore(_PENDING_SLOT, or(pending_, shl(_BIT_ACCEPTED, 0x1)))
            // Emit the {OwnershipHandoverInitiated} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_ACCEPTED_EVENT_SIGNATURE, pendingOwner)
        }
        // console2.logBytes32(stored);
    }

    /// @notice Set the address of the new owner of the contract
    /// @dev Set confirmOwner to address(0) to renounce any ownership.
    /// @param confirmOwner The address of the new owner of the contract
    function transferOwnership(address confirmOwner) public payable virtual {
        address oldOwner = _checkOwner();
        assembly ("memory-safe") {
            let pending_ := sload(_PENDING_SLOT)
            let pause := shr(192, pending_)
            let now_ := timestamp()
            // only if the pending address has been accepted and matches the stored address
            // and we haven't past expiry
            if or(
                iszero(eq(or(confirmOwner, shl(_BIT_ACCEPTED, 0x1)), shr(95, shl(95, pending_)))),
                or(
                    // within the timescales allowed
                    gt(now_, add(pause, shr(232, shl(64, pending_)))),
                    gt(pause, now_)
                )
            ) {
                mstore(0x00, 0xb7b14e20) // `CannotCompleteHandover()`.
                revert(0x1c, 0x04)
            }
            sstore(_PENDING_SLOT, 0)
        }
        _setOwner(oldOwner, confirmOwner);
    }

    // TODO: add this
    // function recoverOwnership(address fromAddress) public payable {
    // only previous owner, not the one who deployed it, though
    // i.e. set up in complete ownership transfer
    // can only recover if it is executed within an expiry period - e.g. 1 or 2 weeks
    // }

    /*//////////////////////////////////////////////////////////////////////////
                                  PRIVATE DATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The owner slot is given by:
    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.owner")) - 1)) & ~bytes32(uint256(0xff))`.
    /// The choice of manual storage layout is to enable compatibility
    /// with both regular and upgradeable contracts.
    bytes32 private constant _INITIALIZED_SLOT = 0x61e0b85c03e2cf9c545bde2fb12d0bf5dd6eaae0af8b6909bd36e40f78a60500;
    // | 255, 1 bit - intialized and zero | 159, 160 bits - owner address |
    uint8 private constant _BIT_INITIALIZED = 255;

    /// @dev The pending owner slot is given by:
    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.pending")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _PENDING_SLOT = 0x9839bd1b7d13bef2e7a66ce106fd5e418f9f8fee5da4e55d26c2c33ef0bf4800;
    // | 255, 64 bits - accept expiry/end of pause timestamp | 191, 24 bits - completion delta | 160, 1 bit - accepted | 159, 160 bits - pending owner address |
    // initialisation:
    //      accept expiry = now, completion delta = 1 hour, accepted = true
    // transfer:
    //      accept expiry = now + 2 days, completion delta = 2 days, accepted = false
    //      accepted = true
    // renounce:
    //      accept expiry = now + 2 days, completion delta = 2 days, accepted = true

    uint8 private constant _BIT_ACCEPTED = 160;

    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.isInitialized")) - 1)) & ~bytes32(uint256(0xff))`.
    //bytes32 private constant _IS_INITIALIZED_SLOT = 0xf62b6656174671598fb5a8f20c699816e60e61b09b105786e842a4b16193e900;
    /// @dev OR an address to get the address stored in owner, if they were also the deployer

    // TODO: change events to be closer to OZ
    // TODO: change function names to be closer to OZ
    /// @dev `keccak256(bytes("OwnershipHandoverInitiated(address)"))`.
    uint256 private constant _OWNERSHIP_HANDOVER_INITIATED_EVENT_SIGNATURE =
        0x7e08cd8a10d06b3112fb4a0df51a5a33057486f1e11def7aec1da5eb5550a0b5;
    /// @dev `keccak256(bytes("OwnershipHandoverCanceled(address)"))`.
    uint256 private constant _OWNERSHIP_HANDOVER_CANCELED_EVENT_SIGNATURE =
        0xfa7b8eab7da67f412cc9575ed43464468f9bfbae89d1675917346ca6d8fe3c92;
    /// @dev `keccak256(bytes("OwnershipHandoverAccepted(address)"))`.
    uint256 private constant _OWNERSHIP_HANDOVER_ACCEPTED_EVENT_SIGNATURE =
        0x76eeb3c9d0f79b85282cbba0fa9820f6cd6bc3acf1858a48d7cad4ec4064c862;
    /// @dev `keccak256(bytes("OwnershipTransferred(address,address)"))`.
    uint256 private constant _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE =
        0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0;

    uint64 private constant _HANDOVER_EXPIRY_PERIOD = 4 days;
    uint64 private constant _HANDOVER_HALF_EXPIRY_PERIOD = 2 days; // needn't be half, just somewhere inbetween

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Sets the owner directly
    /// @param oldOwner, The old owner about to be replaced. This is a clean address (i.e. top bits are zero)
    /// @param newOwner, The new owner about to replace `oldOwner`. This is not a clean address (i.e. top bits may not be zero)
    function _setOwner(address oldOwner, address newOwner) internal {
        // bytes32 stored;
        assembly ("memory-safe") {
            // Emit the {OwnershipTransferred} event with cleaned addresses
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, oldOwner, newOwner)
            // Store the new value. with initialised bit set, to prevent multiple initialisations
            // i.e. an initialisation after a ownership transfer
            // also conditionally clears the deployer bit so it only works once
            // stored := or(newOwner, shl(_BIT_INITIALIZED, 0x1))
            sstore(_INITIALIZED_SLOT, or(newOwner, shl(_BIT_INITIALIZED, iszero(newOwner))))
        }
        // console2.logBytes32(stored);
    }

    function _setPending(
        address pendingOwner,
        uint64 step2ExpiryDelta,
        bool accepted,
        uint24 step3ExpiryDelta
    ) internal {
        // bytes32 stored;
        assembly ("memory-safe") {
            // stored := or(
            //     or(or(pendingOwner, shl(_BIT_ACCEPTED, accepted)), shl(192, add(timestamp(), step2ExpiryDelta))),
            //     shl(168, step3ExpiryDelta)
            // )
            sstore(
                _PENDING_SLOT,
                or(
                    or(or(pendingOwner, shl(_BIT_ACCEPTED, accepted)), shl(192, add(timestamp(), step2ExpiryDelta))),
                    shl(168, step3ExpiryDelta)
                )
            )
            // Emit the {OwnershipHandoverInitiated} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_INITIATED_EVENT_SIGNATURE, pendingOwner)
        }
        // console2.logBytes32(stored);
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual returns (address owner_) {
        assembly ("memory-safe") {
            owner_ := sload(_INITIALIZED_SLOT)
            // If the caller is not the stored owner, revert.
            if iszero(eq(caller(), owner_)) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Marks a function as only callable by the owner.
    modifier onlyOwner() virtual {
        _checkOwner(); // wake-disable-line unchecked-return-value
        _;
    }
}
