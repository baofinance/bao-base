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
        assembly ("memory-safe") {
            // Clean the upper 96 bits.
            initialOwner := shr(96, shl(96, initialOwner))
            // if (owner == address(0)) revert Ownable.NewOwnerIsZeroAddress();
            if iszero(initialOwner) {
                mstore(0x00, 0x7448fbae) // `NewOwnerIsZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // if (ownerSlot != 0) revert AlreadyInitialized();
            let ownerSlot := _OWNER_SLOT
            if sload(ownerSlot) {
                mstore(0x00, 0x0dc149f0) // `AlreadyInitialized()`.
                revert(0x1c, 0x04)
            }
            // Store the value. second top bit set if owner is caller - this allows the one shot 1-step transfer
            sstore(ownerSlot, or(initialOwner, shl(254, eq(caller(), initialOwner))))
            // Emit the {OwnershipTransferred} event.
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, 0, initialOwner)
        }
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
        /// @solidity memory-safe-assembly
        assembly {
            result := sload(_OWNER_SLOT)
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
    /// @param newOwner The address of the new owner.
    function transferOwnership(address newOwner) public payable virtual onlyDeployerOnce {
        // note: the below allow a zero address, because it is can only called in deployment
        assembly ("memory-safe") {
            // don't allow handover to address(0), use the renunciation process
            if iszero(newOwner) {
                mstore(0x00, 0x7448fbae) // `NewOwnerIsZeroAddress()`.
                revert(0x1c, 0x04)
            }
        }
        _setOwner(newOwner);
    }

    /// @notice renouces the ownership in a one-step procedure
    /// Can only be called once and then only by the deployer, who is also the (temporary) owner
    function renounceOwnership() public payable virtual onlyDeployerOnce {
        _setOwner(address(0));
    }

    /// @dev Request a two-step ownership handover to the caller, who cannot be the current owner
    /// The request will automatically expire in 4 days by default.
    function requestOwnershipHandover() public payable virtual {
        //unchecked {
        uint256 expires = block.timestamp + _ownershipHandoverValidFor();

        assembly ("memory-safe") {
            // If the current owner then this cannot be completed
            let owner_ := shr(96, shl(96, sload(_OWNER_SLOT)))
            if iszero(owner_) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // If the caller is the stored owner, then it's a null operation
            if eq(caller(), owner_) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }

            // Compute and set the handover slot to `expires`.
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, caller())
            sstore(keccak256(0x0c, 0x20), expires)
            // Emit the {OwnershipHandoverRequested} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_REQUESTED_EVENT_SIGNATURE, caller())
        }
        //}
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
    function completeOwnershipHandover(
        address pendingOwner
    ) public payable virtual onlyOwner onlyWhenAllowed(pendingOwner) {
        assembly ("memory-safe") {
            // don't allow handover to address(0), use the renunciation process
            if iszero(pendingOwner) {
                mstore(0x00, 0x7448fbae) // `NewOwnerIsZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // Compute and set the handover slot to 0.
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, pendingOwner)
            let handoverSlot := keccak256(0x0c, 0x20)
            // Set the handover slot to 0.
            sstore(handoverSlot, 0)
        }
        _setOwner(pendingOwner);
    }

    function requestOwnershipRenunciation() public payable virtual onlyOwner {
        // similar to requestOwnershipHandover
        unchecked {
            uint256 expires = block.timestamp + _ownershipHandoverValidFor();
            assembly ("memory-safe") {
                // Compute and set the handover slot to `expires`.
                mstore(0x0c, _HANDOVER_SLOT_SEED)
                mstore(0x00, 0)
                sstore(keccak256(0x0c, 0x20), expires)
                // Emit the {OwnershipHandoverRequested} event.
                log2(0, 0, _OWNERSHIP_HANDOVER_REQUESTED_EVENT_SIGNATURE, 0)
            }
        }
    }

    function cancelOwnershipRenunciation() public payable virtual onlyOwner {
        assembly ("memory-safe") {
            // Compute and set the handover slot to 0.
            mstore(0x0c, _HANDOVER_SLOT_SEED)
            mstore(0x00, 0)
            sstore(keccak256(0x0c, 0x20), 0)
            // Emit the {OwnershipHandoverCanceled} event.
            log2(0, 0, _OWNERSHIP_HANDOVER_CANCELED_EVENT_SIGNATURE, 0)
        }
    }

    function completeOwnershipRenunciation() public payable onlyOwner onlyWhenAllowed(address(0)) {
        _setOwner(address(0));
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

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // TODO: make a private constant
    function _ownershipHandoverValidFor() internal pure returns (uint64) {
        return 4 days;
    }

    /// @dev Sets the owner directly without authorization guard.
    function _setOwner(address newOwner) internal virtual {
        assembly ("memory-safe") {
            let ownerSlot := _OWNER_SLOT
            // Clean the upper 96 bits.
            newOwner := shr(96, shl(96, newOwner))
            // Emit the {OwnershipTransferred} event.
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, shr(96, shl(96, sload(ownerSlot))), newOwner)
            // Store the new value. with top bit set if zero, to prevent multiple initialisations
            // i.e. an initialisation after a ownership transfer
            // also clears the deployer bit so it only works once
            sstore(ownerSlot, or(newOwner, shl(255, iszero(newOwner))))
        }
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual {
        assembly ("memory-safe") {
            // If the caller is not the stored owner, revert.
            if iszero(eq(caller(), shr(96, shl(96, sload(_OWNER_SLOT))))) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier onlyDeployerOnce() {
        assembly ("memory-safe") {
            // if the caller is not the deployer and the current owner at the same time, revert
            if iszero(eq(or(caller(), _MASK_DEPLOYER), sload(_OWNER_SLOT))) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
        _;
    }

    modifier onlyWhenAllowed(address pendingOwner) {
        // not before a certain period has transpired since the request
        unchecked {
            uint256 period = _ownershipHandoverValidFor();
            assembly ("memory-safe") {
                // Compute and set the handover slot to 0.
                mstore(0x0c, _HANDOVER_SLOT_SEED)
                mstore(0x00, pendingOwner)
                let handoverSlot := keccak256(0x0c, 0x20)
                // If the handover does not exist, or has expired.
                let now_ := timestamp()
                let expiry := sload(handoverSlot)
                if gt(now_, expiry) {
                    mstore(0x00, 0x6f5e8818) // `NoHandoverRequest()`.
                    revert(0x1c, 0x04)
                }
                if lt(now_, sub(expiry, shr(1, period))) {
                    mstore(0x00, 0x2cb8b3dc) // CannotCompleteYet()
                    revert(0x1c, 0x04)
                }
                // Set the handover slot to 0.
                sstore(handoverSlot, 0)
            }
        }
        _;
    }

    /// @dev Marks a function as only callable by the owner.
    modifier onlyOwner() virtual {
        _checkOwner();
        _;
    }
}
