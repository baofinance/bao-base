// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoCheckOwner} from "@bao/internal/BaoCheckOwner.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

/// @title Harbor Check Owner
/// @notice The owner check of the Harbor generation of mixins - HarborOwnable, HarborRoles, TokenHolder_v2 - which
///         follows HarborOwnable's hand-over: the stored owner owns the contract until the pending owner's time has
///         come, then the pending owner does, with no call needed.
/// @dev One definition, inherited by every mixin that checks the owner, so a contract composing several of them
///      resolves `_checkOwner` to this one and needs no override of its own. It reads the two slots HarborOwnable
///      writes; BaoCheckOwner's stored-owner rule serves the Bao generation unchanged.
abstract contract HarborCheckOwner is BaoCheckOwner {
    /// @dev The pending owner slot is given by:
    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.pending")) - 1)) & ~bytes32(uint256(0xff))`.
    /// | 255, 64 bits - when the pending owner becomes the owner | 191, 32 bits - spare | 159, 160 bits - pending owner |
    bytes32 internal constant _PENDING_SLOT = 0x9839bd1b7d13bef2e7a66ce106fd5e418f9f8fee5da4e55d26c2c33ef0bf4800;

    /// @dev The owner. The pending slot alone answers once its entry's time has come: the entry's owner, zero for an
    /// announced renounce. Before that time, or with no entry - a contract upgraded onto this mixin never wrote one -
    /// the stored owner answers. After any hand-over, then, an owner check is one read.
    function _owner() internal view returns (address owner_) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let pending_ := sload(_PENDING_SLOT)
            // slither-disable-next-line timestamp
            switch and(iszero(iszero(pending_)), iszero(lt(timestamp(), shr(192, pending_))))
            case 1 {
                owner_ := shr(96, shl(96, pending_))
            }
            default {
                owner_ := shr(96, shl(96, sload(_INITIALIZED_SLOT)))
            }
        }
    }

    /// @dev Throws if the sender is not the owner `_owner()` reports, so `onlyOwner` follows the hand-over.
    function _checkOwner() internal view virtual override {
        if (msg.sender != _owner()) {
            revert IHarborOwnable.Unauthorized();
        }
    }
}
