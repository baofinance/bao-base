// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Ownable } from "@solady/auth/Ownable.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";
import { IOwnable } from "@bao/interfaces/IOwnable.sol";

/// @title Bao Ownable
/// @notice A thin layer over Solady's Ownable that constrains the use of one-step ownership transfers:
/// Only the deployer of the contract can perform a one-step ownership transfer and then
///   * only once and
///   * only if they have been set as owner on initialisation
/// This simplifies deploy scripts that must do owner type set-up but then can transfer to the real owner once done
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
abstract contract BaoOwnable is Ownable, ERC165Upgradeable {
    /*//////////////////////////////////////////////////////////////
                             CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @dev Can only carry out actions within a window of time.
    error CannotCompleteYet();

    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice initialise the UUPS proxy
    /// @param owner sets the owner, a privileged address, of the contract. Cannot be address(0)
    function _initializeOwner(address owner) internal virtual override(Ownable) {
        assembly ("memory-safe") {
            // Clean the upper 96 bits.
            owner := and(owner, _MASK_ADDRESS)
            // if (owner == address(0)) revert Ownable.NewOwnerIsZeroAddress();
            if iszero(owner) {
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
            sstore(ownerSlot, or(owner, shl(254, eq(caller(), owner))))
            // Emit the {OwnershipTransferred} event.
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, 0, owner)
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaoOwnable).interfaceId ||
            interfaceId == type(IOwnable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice transfers the ownership to a 'newOwner' in a one-step procedure
    /// Can only be called once and then only by the deployer, who is also the (temporary) owner
    /// @param newOwner The address of the new owner.
    function transferOwnership(address newOwner) public payable virtual override(Ownable) onlyDeployerOnce {
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
    function renounceOwnership() public payable virtual override(Ownable) onlyDeployerOnce {
        _setOwner(address(0));
    }

    /// @dev Request a two-step ownership handover to the caller, who cannot be the current owner
    /// The request will automatically expire in 4 days by default.
    function requestOwnershipHandover() public payable virtual override(Ownable) {
        assembly ("memory-safe") {
            // If the current owner then this cannot be completed
            let owner_ := and(sload(_OWNER_SLOT), _MASK_ADDRESS)
            if iszero(owner_) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
            // If the caller is the stored owner, then it's a null operation
            if eq(caller(), owner_) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
        Ownable.requestOwnershipHandover();
    }

    /// @notice add a period (half the timeout) in which this function cannot be called
    function completeOwnershipHandover(
        address pendingOwner
    ) public payable virtual override(Ownable) onlyOwner onlyWhenAllowed(pendingOwner) {
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

    function requestOwnershipRenunciation() public payable onlyOwner {
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

    function cancelOwnershipRenunciation() public payable onlyOwner {
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

    /// @dev AND a slot with MASK_ADDRESS to clean top 96 bits of the address
    bytes32 private constant _MASK_ADDRESS = 0x000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    /// @dev AND a slot with MASK_DEPLOYER to reveal the bit that says the owner is the deployer
    bytes32 private constant _MASK_DEPLOYER = 0x4000000000000000000000000000000000000000000000000000000000000000;

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _ownershipHandoverValidFor() internal view virtual override(Ownable) returns (uint64) {
        return 4 days; // 2 days pause and 2 further days to complete
    }

    /// @dev Sets the owner directly without authorization guard.
    function _setOwner(address newOwner) internal virtual override(Ownable) {
        assembly ("memory-safe") {
            let ownerSlot := _OWNER_SLOT
            // Clean the upper 96 bits.
            newOwner := and(newOwner, _MASK_ADDRESS)
            // Emit the {OwnershipTransferred} event.
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, and(sload(ownerSlot), _MASK_ADDRESS), newOwner)
            // Store the new value. with top bit set if zero, to prevent multiple initialisations
            // i.e. an initialisation after a ownership transfer
            // also clears the deployer bit so it only works once
            sstore(ownerSlot, or(newOwner, shl(255, iszero(newOwner))))
        }
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual override(Ownable) {
        assembly ("memory-safe") {
            // If the caller is not the stored owner, revert.
            if iszero(eq(caller(), and(sload(_OWNER_SLOT), _MASK_ADDRESS))) {
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
}
