// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaoCheckOwner} from "@bao/internal/BaoCheckOwner.sol";
import {Token} from "./Token.sol";
import {ITokenHolder} from "./interfaces/ITokenHolder.sol";

abstract contract TokenHolder is ReentrancyGuardTransientUpgradeable, BaoCheckOwner, ITokenHolder {
    using SafeERC20 for IERC20;

    /// @notice function to transfer owned owned balance of a token
    /// This allows. for example dust resulting from rounding errors, etc.
    /// in case tokens are transferred to this contract by mistake, they can be recovered
    function sweep(address token, uint256 amount, address receiver) external onlySweeper nonReentrant {
        _sweep(token, amount, receiver);
    }

    function _sweep(address token, uint256 amount, address receiver) internal virtual {
        Token.ensureNonZeroAddress(receiver);
        amount = Token.allOf(address(this), token, amount);
        emit Swept(token, amount, receiver);
        if (amount > 0) {
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
    modifier onlySweeper() virtual {
        _checkSweeper();
        _;
    }
}
