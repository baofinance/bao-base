// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {HarborCheckOwner} from "@bao/internal/HarborCheckOwner.sol";
import {ERC165} from "@bao/ERC165.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

/// @title Harbor Ownable
/// @dev Note:
/// You MUST call `_initializeOwner(...)` in the constructor / initializer of the deriving contract.
///
/// The initialization (`_initializeOwner(address deployerOwner, address pendingOwner)`) names the deployer owner rather
/// than reading `msg.sender`, so it works when the initializer runs inside a factory's deploy.
///
/// Ownership hands over by itself, as in HarborFixedOwnable, which keeps the same two owners in immutables: the
/// deployer owner owns the contract for one hour from initialization, to configure it, and from then on the pending
/// owner owns it, with no call needed. The deployer may hand over earlier with `transferOwnership(pendingOwner)`. No
/// other ownership transfer is supported. Every owner check - `onlyOwner`, and the owner-or-roles checks of the roles
/// variant - sees the owner that `owner()` reports.
///
/// This contract follows [EIP-173](https://eips.ethereum.org/EIPS/eip-173) for compatibility: both transitions are
/// announced at initialization, as HarborFixedOwnable announces them at construction.
///
/// Multiple initialisations are not allowed, to ensure this we make a separate check for a previously set owner including
/// including to address(0). This ensure that the initializeOwner, an otherwise unprotected function, cannot be called twice.
///
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage

abstract contract HarborOwnable is IHarborOwnable, HarborCheckOwner, ERC165 {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Initialises the ownership: `deployerOwner` owns the contract for `_HAND_OVER_DELAY`, then
    /// `pendingOwner_` does.
    /// @dev Reads no `msg.sender`. Both transitions are announced now.
    /// @param deployerOwner The owner for the first hour, to configure the contract.
    /// @param pendingOwner_ The owner from an hour on, or from earlier if `deployerOwner` hands over.
    // slither-disable-next-line dead-code
    function _initializeOwner(address deployerOwner, address pendingOwner_) internal virtual {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // once only: the owner slot is non-zero after any initialisation, the initialised bit covering a zero owner
            if sload(_INITIALIZED_SLOT) {
                mstore(0x00, 0x0dc149f0) // `AlreadyInitialized()`.
                revert(0x1c, 0x04)
            }
            sstore(_PENDING_SLOT, or(pendingOwner_, shl(192, add(timestamp(), _HAND_OVER_DELAY))))
            sstore(_INITIALIZED_SLOT, or(deployerOwner, shl(_BIT_INITIALIZED, iszero(deployerOwner))))
            // both transitions announced now, as HarborFixedOwnable announces them at construction
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, 0, deployerOwner)
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, deployerOwner, pendingOwner_)
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IHarborOwnable).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IHarborOwnable
    /// @dev The owner every owner check sees: the pending owner once its time has come, otherwise the stored owner.
    function owner() public view virtual returns (address owner_) {
        owner_ = _owner();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborOwnable
    /// @dev Brings the hand-over announced at initialisation forward to now, by the owner: the entry's time becomes
    /// the block's, so the pending owner owns the contract from here. After its time it is in effect already and this
    /// changes nothing. Reverts `CannotCompleteTransfer` when there is no entry or `confirmOwner` is not its owner.
    function transferOwnership(address confirmOwner) public virtual {
        _checkOwner();
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let pending_ := sload(_PENDING_SLOT)
            if or(
                // an entry must exist: an empty slot would otherwise match a zero confirmOwner
                iszero(pending_),
                // confirm == pending
                iszero(eq(confirmOwner, shr(96, shl(96, pending_))))
            ) {
                mstore(0x00, 0x8cd65fff) // `CannotCompleteTransfer()`.
                revert(0x1c, 0x04)
            }
            sstore(_PENDING_SLOT, or(confirmOwner, shl(192, timestamp())))
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PRIVATE DATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The owner slot is defined in BaoCheckOwner and the pending owner slot in HarborCheckOwner.
    /// We utilise an extra bit in the owner slot, to prevent re-initialisations (only needed for address(0))
    uint8 internal constant _BIT_INITIALIZED = 255;

    /// @dev How long the deployer owner owns the contract from initialisation, before the pending owner does.
    uint256 internal constant _HAND_OVER_DELAY = 1 hours;

    /// @dev `keccak256(bytes("OwnershipTransferred(address,address)"))`.
    uint256 internal constant _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE =
        0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0;
}
