// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

/// @title Bao Check Owner
/// @dev Note:
/// provides a modifier that throws if the caller is not the owner
/// @author rootminus0x1 taken from Solady's Ownable contract (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
/// @dev Uses erc7201 storage
// solhint-disable-next-line contract-name-camelcase
abstract contract BaoCheckOwner_v2 {
    /*//////////////////////////////////////////////////////////////////////////
                                   INTERNAL DATA
    //////////////////////////////////////////////////////////////////////////*/

    address private immutable _BEFORE_OWNER;
    uint256 private immutable _OWNER_TRANSFER_AT;
    address private immutable _OWNER_AT;

    /*//////////////////////////////////////////////////////////////////////////
                                 INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    constructor(address delayedOwner, uint256 delay) {
        _BEFORE_OWNER = msg.sender;
        _OWNER_TRANSFER_AT = block.timestamp + delay;
        _OWNER_AT = delayedOwner;
        emit IBaoOwnable.OwnershipTransferred(address(0), _BEFORE_OWNER);
        emit IBaoOwnable.OwnershipTransferred(_BEFORE_OWNER, _OWNER_AT);
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual {
        if (msg.sender != _owner()) {
            revert IBaoOwnable.Unauthorized();
        }
    }

    // @inheritdoc IBaoOwnable
    function _owner() internal view virtual returns (address owner_) {
        // check against the transfer time to see if it has happened
        // slither-disable-next-line timestamp
        owner_ = (block.timestamp >= _OWNER_TRANSFER_AT) ? _OWNER_AT : _BEFORE_OWNER;
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
