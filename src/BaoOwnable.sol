// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";

/// @title Bao Ownable
/// @notice A thin layer over Solady's Ownable that constrains the use of one-step ownership transfers:
/// Only the deployer of the contract can perform a one-step ownership transfer and then
///   * only once and
///   * only if they have been set as owner on initialisation
/// This simplifies deploy scripts that must do owner type set-up but then can transfer to the real owner once done
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
abstract contract BaoOwnable is IERC165, IBaoOwnable {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice initialise the UUPS proxy
    /// @param initialOwner sets the owner, a privileged address, of the contract. Cannot be address(0)
    function _initializeOwner(address initialOwner) internal virtual {
        bytes32 newOwner;
        assembly ("memory-safe") {
            newOwner := initialOwner
            // if (owner == address(0)) revert Ownable.NewOwnerIsZeroAddress();
            if iszero(newOwner) {
                mstore(0x00, 0x7448fbae) // `NewOwnerIsZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // record that deployer is the owner so that deployer gets a shot at changing that 1-step
            if eq(caller(), newOwner) {
                newOwner := or(newOwner, _MASK_DEPLOYER)
            }
            // if (ownerSlot != 0) revert AlreadyInitialized();
            if sload(_OWNER_SLOT) {
                mstore(0x00, 0x0dc149f0) // `AlreadyInitialized()`.
                revert(0x1c, 0x04)
            }
        }
        _setOwner(0, newOwner);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBaoOwnable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Returns the owner of the contract.
    function owner() public view virtual returns (address result) {
        unchecked {
            /// @solidity memory-safe-assembly
            assembly {
                // TODO: this cleaning seems to have no effect - is it because address returns are always clean
                result := shr(96, shl(96, sload(_OWNER_SLOT)))
            }
        }
    }

    function ownershipHandoverExpiresAt(address pendingOwner) public view virtual returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the handover slot.
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, pendingOwner)
            // Load the handover slot.
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice transfers the ownership to a 'newOwner' in a one-step procedure
    /// Can only be called once and then only by the deployer, who is also the (temporary) owner
    /// @param toOwner The address of the new owner.
    function transferOwnership(address toOwner) public payable virtual {
        bytes32 oldOwner = _checkTransferOwnership();
        bytes32 newOwner;
        assembly ("memory-safe") {
            newOwner := toOwner
            // don't allow handover to address(0), use the renunciation process
            if iszero(newOwner) {
                mstore(0x00, 0x7448fbae) // `NewOwnerIsZeroAddress()`.
                revert(0x1c, 0x04)
            }
        }
        _setOwner(oldOwner, newOwner);
    }

    /// @notice renounces the ownership in a one-step procedure
    /// Can only be called once and then only by the deployer, who is also the (temporary) owner
    function renounceOwnership() public payable virtual {
        _setOwner(_checkTransferOwnership(), _INITIALIZED_ZERO_ADDRESS);
    }

    /// @notice transfers the ownership in a one-step procedure
    /// Can only be called once and then only by the deployer, who is also the (temporary) owner
    function _checkTransferOwnership() private view returns (bytes32 oldOwner) {
        assembly ("memory-safe") {
            oldOwner := sload(_OWNER_SLOT)
            // if the caller is not the deployer and the current owner at the same time, revert
            if iszero(eq(or(caller(), _MASK_DEPLOYER), oldOwner)) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // clean oldOwner address (i.e. if it was zero)
            oldOwner := shr(96, shl(96, oldOwner))
        }
    }

    /// @dev Request a two-step ownership handover to the caller, who cannot be the current owner
    /// The request will automatically expire in 4 days by default.
    function requestOwnershipHandover() public payable virtual {
        assembly ("memory-safe") {
            // TODO: can we remove this check?
            // If the current owner is zero then this cannot be completed
            let owner_ := shr(96, shl(96, sload(_OWNER_SLOT)))
            if iszero(owner_) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
        _setTransferRequest(msg.sender);
    }

    /// @dev Cancels the two-step ownership handover to the caller, if any.
    function cancelOwnershipHandover() public payable virtual {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute and set the handover slot to 0.
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, caller())
            sstore(keccak256(0x0c, 0x20), 0)
            // Emit the {OwnershipHandoverCanceled} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_CANCELED_EVENT_SIGNATURE, caller())
        }
    }

    /// @notice add a period (half the timeout) in which this function cannot be called
    function completeOwnershipHandover(address pendingOwner) public payable virtual {
        unchecked {
            bytes32 oldOwner = _checkOwner();
            bytes32 newOwner;
            assembly ("memory-safe") {
                newOwner := pendingOwner
                // don't allow handover to address(0), use the renunciation process
                if iszero(newOwner) {
                    mstore(0x00, 0x7448fbae) // `NewOwnerIsZeroAddress()`.
                    revert(0x1c, 0x04)
                }
            }
            _checkCompletionWindow(pendingOwner);
            _setOwner(oldOwner, newOwner);
        }
    }

    function requestOwnershipRenunciation() public payable virtual {
        _checkOwner(); // wake-disable-line unchecked-return-value
        _setTransferRequest(address(0));
    }

    function cancelOwnershipRenunciation() public payable virtual {
        unchecked {
            _checkOwner(); // wake-disable-line unchecked-return-value
            assembly ("memory-safe") {
                // Compute and set the handover slot to 0.
                mstore(0x0c, _HANDOVER_SLOT_SEED)
                mstore(0x00, 0)
                sstore(keccak256(0x0c, 0x20), 0)
                // Emit the {OwnershipHandoverCanceled} event.
                log2(0, 0, _OWNERSHIP_HANDOVER_CANCELED_EVENT_SIGNATURE, 0)
            }
        }
    }

    function completeOwnershipRenunciation() public payable {
        unchecked {
            bytes32 oldOwner = _checkOwner();
            _checkCompletionWindow(address(0));
            _setOwner(oldOwner, _INITIALIZED_ZERO_ADDRESS);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PRIVATE DATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The owner slot is given by:
    /// `bytes32(~uint256(uint32(bytes4(keccak256("_OWNER_SLOT_NOT")))))`.
    /// It is intentionally chosen to be a high value
    /// to avoid collision with lower slots.
    /// The choice of manual storage layout is to enable compatibility
    /// with both regular and upgradeable contracts.
    bytes32 private constant _OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;

    // @dev copied from Ownable - must remain the same as Ownable's
    uint256 private constant _HANDOVER_SLOT_SEED = 0x389a75e1;
    /// @dev `keccak256(bytes("OwnershipHandoverCanceled(address)"))`.
    uint256 private constant _OWNERSHIP_HANDOVER_CANCELED_EVENT_SIGNATURE =
        0xfa7b8eab7da67f412cc9575ed43464468f9bfbae89d1675917346ca6d8fe3c92;
    /// @dev `keccak256(bytes("OwnershipHandoverRequested(address)"))`.
    uint256 private constant _OWNERSHIP_HANDOVER_REQUESTED_EVENT_SIGNATURE =
        0xdbf36a107da19e49527a7176a1babf963b4b0ff8cde35ee35d6cd8f1f9ac7e1d;
    /// @dev `keccak256(bytes("OwnershipTransferred(address,address)"))`.
    uint256 private constant _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE =
        0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0;

    /// @dev AND a slot with MASK_DEPLOYER to reveal the bit that says the owner is the deployer
    bytes32 private constant _MASK_DEPLOYER = 0x4000000000000000000000000000000000000000000000000000000000000000;

    /// @dev zero address is stored like this so we can detect an initialised-to-zero value from an uninitialises address
    bytes32 private constant _INITIALIZED_ZERO_ADDRESS =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    uint64 private constant _TRANSFER_EXPIRY_PERIOD = 4 days;

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Sets the owner directly
    /// @param oldOwner, The old owner about to be replaced. This is a clean address (i.e. top bits are zero)
    /// @param newOwner, The new owner about to replace `oldOwner`. This is not a clean address (i.e. top bits may not be zero)
    function _setOwner(bytes32 oldOwner, bytes32 newOwner) private {
        assembly ("memory-safe") {
            // Emit the {OwnershipTransferred} event with cleaned addresses
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, oldOwner, shr(96, shl(96, newOwner)))
            // Store the new value. with top bit set if zero, to prevent multiple initialisations
            // i.e. an initialisation after a ownership transfer
            // also clears the deployer bit so it only works once
            sstore(_OWNER_SLOT, newOwner)
        }
    }

    function _setTransferRequest(address toOwner) private {
        assembly ("memory-safe") {
            // Compute and set the handover slot to `expires`.
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, toOwner)
            sstore(keccak256(0x0c, 0x20), add(timestamp(), _TRANSFER_EXPIRY_PERIOD))
            // Emit the {OwnershipHandoverRequested} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_REQUESTED_EVENT_SIGNATURE, toOwner)
        }
    }

    function _checkCompletionWindow(address requestor) private {
        assembly ("memory-safe") {
            // get the expiry for pendingOwner
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, requestor)
            let handoverSlot := keccak256(0x0c, 0x20)
            // If the handover does not exist, or has expired.
            let now_ := timestamp()
            let expiry := sload(handoverSlot)
            if gt(now_, expiry) {
                mstore(0x00, 0x6f5e8818) // `NoHandoverRequest()`.
                revert(0x1c, 0x04)
            }
            if lt(now_, sub(expiry, shr(1, _TRANSFER_EXPIRY_PERIOD))) {
                mstore(0x00, 0x2cb8b3dc) // CannotCompleteYet()
                revert(0x1c, 0x04)
            }
            // set the handover slot to 0.
            sstore(handoverSlot, 0)
        }
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual returns (bytes32 owner_) {
        assembly ("memory-safe") {
            // If the caller is not the stored owner, revert.
            owner_ := shr(96, shl(96, sload(_OWNER_SLOT)))
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
