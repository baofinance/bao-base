// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC165} from "@bao/ERC165.sol";
import {IBaoFixedOwnable} from "@bao/interfaces/IBaoFixedOwnable.sol";

/// @title Bao Fixed Ownable
/// @notice Ownable where the initial owner and delayed owner are constructor-fixed.
/// @dev Similar to BaoOwnable_v2, but does not read `msg.sender` internally.
/// Instead, the "before" owner is an explicit constructor parameter.
///
/// Ownership transitions automatically from `beforeOwner` to `delayedOwner` after `delay` seconds.
/// No additional ownership transfers are supported.
abstract contract BaoFixedOwnable is IBaoFixedOwnable, ERC165 {
    /*//////////////////////////////////////////////////////////////////////////
                                   INTERNAL DATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _BEFORE_OWNER;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 private immutable _OWNER_TRANSFER_AT;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _OWNER_AT;

    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploys and fixes the ownership transition.
    /// @param beforeOwner The owner address before the delay elapses.
    /// @param delayedOwner The owner address after the delay elapses. Cannot be zero.
    /// @param delay The delay (in seconds) after which ownership switches.
    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor(address beforeOwner, address delayedOwner, uint256 delay) {
        if (delayedOwner == address(0)) {
            revert IBaoFixedOwnable.ZeroOwner();
        }
        _BEFORE_OWNER = beforeOwner;
        _OWNER_TRANSFER_AT = block.timestamp + delay;
        _OWNER_AT = delayedOwner;

        emit IBaoFixedOwnable.OwnershipTransferred(address(0), _BEFORE_OWNER);
        emit IBaoFixedOwnable.OwnershipTransferred(_BEFORE_OWNER, _OWNER_AT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view virtual {
        if (msg.sender != _owner()) {
            revert IBaoFixedOwnable.Unauthorized();
        }
    }

    /// @dev Returns the current owner address.
    function _owner() internal view virtual returns (address owner_) {
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

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // @inheritdoc IBaoFixedOwnable
    function owner() public view virtual returns (address owner_) {
        owner_ = _owner();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IBaoFixedOwnable).interfaceId || super.supportsInterface(interfaceId);
    }
}
