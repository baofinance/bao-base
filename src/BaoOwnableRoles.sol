// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaoOwnable } from "@bao/BaoOwnable.sol";
import { BaoRoles } from "@bao/internal/BaoRoles.sol";

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
contract BaoOwnableRoles is BaoOwnable, BaoRoles {
    function supportsInterface(bytes4 interfaceId) public view virtual override(BaoOwnable, BaoRoles) returns (bool) {
        return BaoOwnable.supportsInterface(interfaceId) || BaoRoles.supportsInterface(interfaceId);
    }
}
