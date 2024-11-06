// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// import { console2 } from "forge-std/console2.sol";

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { BaoCheckOwner } from "@bao/internal/BaoCheckOwner.sol";
import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";

/// @title Bao Ownable
/// @dev Note:
/// You MUST call the `_initializeOwner` in the constructor / initializer of the deriving contract.
/// This initialization sets the owner to `msg.sender`, and not to the passed 'finalOwner' parameter.
///
/// This contract follows [EIP-173](https://eips.ethereum.org/EIPS/eip-173) for compatibility,
/// however the transferOwnership function can only be called once and then, only by the cller that calls
/// initializeOwnershi, and then only within 1 hour
///
/// Multiple initialisations are not allowed, to ensure this we make a separate check for a previously set owner including
/// including to address(0). This ensure that the initializeOwner, an otherwise unprotected function, cannot be called twice.
///
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
contract BaoOwnable is IBaoOwnable, BaoCheckOwner, IERC165 {
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
            sstore(_PENDING_SLOT, or(finalOwner, shl(192, add(timestamp(), 3600))))
        }
        unchecked {
            _setOwner(address(0), msg.sender);
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

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Set the address of the new owner of the contract
    /// @dev Set confirmOwner to address(0) to renounce any ownership.
    /// @param confirmOwner The address of the new owner of the contract
    function transferOwnership(address confirmOwner) public payable virtual {
        unchecked {
            address oldOwner;
            assembly ("memory-safe") {
                oldOwner := sload(_INITIALIZED_SLOT)
                if iszero(eq(caller(), oldOwner)) {
                    mstore(0x00, 0x82b42900) // `Unauthorized()`.
                    revert(0x1c, 0x04)
                }
                let pending_ := sload(_PENDING_SLOT)
                if or(
                    // confirm == pending
                    iszero(eq(confirmOwner, shr(95, shl(95, pending_)))),
                    // within the timescale allowed
                    gt(timestamp(), shr(192, pending_))
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

    /// @dev The owner address storage slot is defined in BaoCheckOwner
    /// We utilise an extra bit in that slot, to prevent re-initialisations (only needed for address(0))
    uint8 internal constant _BIT_INITIALIZED = 255;

    /// @dev The pending owner slot is given by:
    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.pending")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 internal constant _PENDING_SLOT = 0x9839bd1b7d13bef2e7a66ce106fd5e418f9f8fee5da4e55d26c2c33ef0bf4800;
    // | 255, 64 bits - expiry | 191, 32 bits - spare | 159, 160 bits - pending owner address |

    uint8 private constant _BIT_VALIDATED = 160;

    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.isInitialized")) - 1)) & ~bytes32(uint256(0xff))`.
    //bytes32 private constant _IS_INITIALIZED_SLOT = 0xf62b6656174671598fb5a8f20c699816e60e61b09b105786e842a4b16193e900;
    /// @dev OR an address to get the address stored in owner, if they were also the deployer

    /// @dev `keccak256(bytes("OwnershipTransferred(address,address)"))`.
    uint256 internal constant _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE =
        0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0;

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Sets the owner directly
    /// @param oldOwner, The old owner about to be replaced. This is a clean address (i.e. top bits are zero)
    /// @param newOwner, The new owner about to replace `oldOwner`. This is not a clean address (i.e. top bits may not be zero)
    function _setOwner(address oldOwner, address newOwner) internal {
        assembly ("memory-safe") {
            // Emit the {OwnershipTransferred} event with cleaned addresses
            log3(0, 0, _OWNERSHIP_TRANSFERRED_EVENT_SIGNATURE, oldOwner, newOwner)
            // Store the new value. with initialised bit set, to prevent multiple initialisations
            // i.e. an initialisation after a ownership transfer
            sstore(_INITIALIZED_SLOT, or(newOwner, shl(_BIT_INITIALIZED, iszero(newOwner))))
        }
    }
}
