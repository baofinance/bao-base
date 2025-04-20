// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

/// @title Bao Check Owner
/// @dev Note:
/// provides a modifier that throws if the caller is not the owner
/// @author rootminus0x1 taken from Solady's Ownable contract (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
/// @dev Uses erc7201 storage
abstract contract BaoCheckOwnerV2 {
    /*//////////////////////////////////////////////////////////////////////////
                                   INTERNAL DATA
    //////////////////////////////////////////////////////////////////////////*/

    address private immutable _beforeOwner;
    uint256 private immutable _ownerTransfersAt;
    address private immutable _ownerAt;

    /*//////////////////////////////////////////////////////////////////////////
                                 INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    constructor(address delayedOwner, uint256 delay) {
        _beforeOwner = msg.sender;
        _ownerTransfersAt = block.timestamp + delay;
        _ownerAt = delayedOwner;
        emit IBaoOwnable.OwnershipTransferred(address(0), _beforeOwner);
        emit IBaoOwnable.OwnershipTransferred(_beforeOwner, _ownerAt);
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual {
        if (msg.sender != _owner()) {
            revert IBaoOwnable.Unauthorized();
        }
    }

    // @inheritdoc IBaoOwnable
    function _owner() internal view virtual returns (address owner_) {
        owner_ = (block.timestamp >= _ownerTransfersAt) ? _ownerAt : _beforeOwner;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Marks a function as only callable by the owner.
    modifier onlyOwner() virtual {
        _checkOwner();
        _;
    }
}
