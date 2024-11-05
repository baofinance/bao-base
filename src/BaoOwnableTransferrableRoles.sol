// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// import { console2 } from "forge-std/console2.sol";

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IBaoOwnableTransferrable } from "@bao/interfaces/IBaoOwnableTransferrable.sol";
import { IBaoRoles } from "@bao/interfaces/IBaoRoles.sol";
import { BaoOwnableTransferrable } from "@bao/BaoOwnableTransferrable.sol";
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
/* TODO: abstract */ contract BaoOwnableTransferrableRoles is BaoOwnableTransferrable, BaoRoles {
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnableTransferrable, BaoRoles) returns (bool) {
        return BaoOwnableTransferrable.supportsInterface(interfaceId) || BaoRoles.supportsInterface(interfaceId);
    }
}
