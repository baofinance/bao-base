// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaoCheckOwnerV2} from "@bao/internal/BaoCheckOwnerV2.sol";
import {ERC165} from "@bao/ERC165.sol";
import {IBaoOwnableV2} from "@bao/interfaces/IBaoOwnableV2.sol";

/// @title Bao Ownable
/// @dev Note:
/// This implementation auto-initialises the owner to `msg.sender`.
/// You MUST call the `_initializeOwner` in the constructor / initializer of the deriving contract.
///
/// BaoOwnable enforces a one-time transfer from the initial deployer to the pending owner
/// This transfer must occur within 1 hour of initialization
/// Once transferred, ownership cannot be transferred again through BaoOwnable's mechanism
///
/// This initialization sets the owner to `msg.sender`, not to the passed 'finalOwner' parameter.
/// The contract deployer can now act as owner then 'transferOwnership' once complete.
///
/// This contract follows [EIP-173](https://eips.ethereum.org/EIPS/eip-173) for compatibility,
/// however the transferOwnership function can only be called once and then, only by the caller that calls
/// initializeOwner, and then only within 1 hour
///
/// Multiple initialisations are not allowed, to ensure this we make a separate check for a previously set owner
/// including to address(0).
/// This ensures that the initializeOwner, an otherwise unprotected function, cannot be called twice.
///
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
abstract contract BaoOwnableV2 is IBaoOwnableV2, BaoCheckOwnerV2, ERC165 {
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Initialises the ownership
    /// This is an unprotected function designed to let a derive contract's initializer to call it
    /// This function can only be called once.
    /// The caller of the initializer function will be the deployer of the contract. The deployer (msg.sender)
    /// becomes the owner, allowing them to do owner-type set up, then ownership is transferred to the 'finalOwner'
    /// when 'transferOwnership' is called. 'transferOwnership' must be called within an hour.
    /// @param finalOwner sets the owner, a privileged address, of the contract to be set when 'transferOwnership' is called
    // slither-disable-next-line dead-code
    constructor(address finalOwner) BaoCheckOwnerV2(finalOwner, 3600) {}

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // @inheritdoc IBaoOwnable
    function owner() public view virtual returns (address owner_) {
        owner_ = _owner();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        // base class doesn't support any interfaces
        return interfaceId == type(IBaoOwnableV2).interfaceId || super.supportsInterface(interfaceId);
    }
}
