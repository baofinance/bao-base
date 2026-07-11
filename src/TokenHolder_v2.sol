// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaoCheckOwner} from "@bao/internal/BaoCheckOwner.sol";
import {Token} from "@bao/Token.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";

/// @title TokenHolder_v2
/// @notice Go-forward TokenHolder built on OpenZeppelin's non-upgradeable `ReentrancyGuardTransient`. Transient
///         storage needs no namespaced storage and no initializer, so there is no `__ReentrancyGuardTransient_init`
///         to call and no dependency on the bao-base remapping shim - a new contract inherits this directly under any
///         OpenZeppelin version. The audited `TokenHolder` (upgradeable guard, reached via the shim + remapping) is
///         kept byte-unchanged for already-deployed contracts; this is its replacement for new code. `sweep` is
///         `virtual` so a derived contract can wrap it (e.g. cap the outflow or change the access check).
// solhint-disable-next-line contract-name-capwords
abstract contract TokenHolder_v2 is ReentrancyGuardTransient, BaoCheckOwner, ITokenHolder {
    using SafeERC20 for IERC20;

    /// @notice function to transfer owned owned balance of a token
    /// This allows. for example dust resulting from rounding errors, etc.
    /// in case tokens are transferred to this contract by mistake, they can be recovered
    // slither-disable-next-line reentrancy-no-eth
    function sweep(address token, uint256 amount, address receiver) external virtual onlySweeper nonReentrant {
        Token.ensureNonZeroAddress(receiver);
        amount = Token.allOf(address(this), token, amount);
        _sweep(token, amount, receiver);
    }

    function _sweep(address token, uint256 amount, address receiver) internal virtual {
        if (amount > 0) {
            emit Swept(token, amount, receiver);
            IERC20(token).safeTransfer(receiver, amount);
        }
    }

    /// @notice function used in the 'onlySweeper' modifier
    /// @dev this can be overridden to control access to the sweep function
    /// @dev it's simpler to override this than the onlySweeper modifier
    function _checkSweeper() internal view virtual {
        _checkOwner();
    }

    /// @notice modifier used by the 'sweep' function
    /// @dev this can be overridden to control access to the sweep function
    /// @dev it's simpler to override the '_checkSweeper' function than this
    modifier onlySweeper() {
        _checkSweeper();
        _;
    }
}
