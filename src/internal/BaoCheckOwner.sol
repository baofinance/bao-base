// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Bao Check Owner
/// @dev Note:
/// provides a modifier that throws if the caller is not the owner
/// @author rootminus0x1 taken from Solady's Ownable contract (https://github.com/vectorized/solady/blob/main/src/auth/Ownable.sol)
/// @dev Uses erc7201 storage
abstract contract BaoCheckOwner {
    /*//////////////////////////////////////////////////////////////////////////
                                   INTERNAL DATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The owner slot is given by:
    /// `keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable.owner")) - 1)) & ~bytes32(uint256(0xff))`.
    /// The choice of manual storage layout is to enable compatibility with both regular and upgradeable contracts.
    bytes32 internal constant _INITIALIZED_SLOT = 0x61e0b85c03e2cf9c545bde2fb12d0bf5dd6eaae0af8b6909bd36e40f78a60500;

    /*//////////////////////////////////////////////////////////////////////////
                                 INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // If the caller is not the stored owner, revert.
            if iszero(eq(caller(), sload(_INITIALIZED_SLOT))) {
                mstore(0x00, 0x82b42900) // `Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Marks a function as only callable by the owner.
    modifier onlyOwner() virtual {
        _checkOwner(); // wake-disable-line unchecked-return-value
        _;
    }
}
