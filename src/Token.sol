// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: check OZ address class

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/*
function totalSupply() external view returns (uint256);
function balanceOf(address account) external view returns (uint256);
function transfer(address to, uint256 value) external returns (bool);
function allowance(address owner, address spender) external view returns (uint256);
function approve(address spender, uint256 value) external returns (bool);
function transferFrom(address from, address to, uint256 value) external returns (bool);
*/

// import {DateUtils} from "DateUtils/DateUtils.sol";

// Attribution: string basics stolen from OpenZeppelin

library Token {
    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error ZeroInputBalance(address token);

    error ZeroAddress();
    error NotContractAddress(address addr);
    error NotERC20Token(address token);

    function allOf(address account, address token, uint256 tokenIn) internal view returns (uint256 actualIn) {
        if (tokenIn == type(uint256).max) {
            actualIn = IERC20(token).balanceOf(account);
        } else {
            actualIn = tokenIn;
        }
        // slither-disable-next-line incorrect-equality
        if (actualIn == 0) {
            revert ZeroInputBalance(token);
        }
    }

    function ensureNonZeroAddress(address that) internal pure {
        if (that == address(0)) revert ZeroAddress();
    }

    function ensureContract(address addr) internal view {
        ensureNonZeroAddress(addr);
        // from https://www.rareskills.io/post/solidity-code-length
        if (addr.code.length == 0) revert NotContractAddress(addr);
    }

    function ensureERC20Token(address addr) internal view {
        ensureContract(addr);
        if (
            // check all the readonly functions that IERC20 supports
            !_hasFunction(addr, abi.encodeWithSelector(IERC20Metadata.name.selector)) ||
            !_hasFunction(addr, abi.encodeWithSelector(IERC20Metadata.symbol.selector)) ||
            !_hasFunction(addr, abi.encodeWithSelector(IERC20Metadata.decimals.selector)) ||
            !_hasFunction(addr, abi.encodeWithSelector(IERC20.totalSupply.selector)) ||
            !_hasFunction(addr, abi.encodeWithSelector(IERC20.balanceOf.selector, address(0))) ||
            !_hasFunction(addr, abi.encodeWithSelector(IERC20.allowance.selector, address(0), address(0)))
        ) {
            revert NotERC20Token(addr);
        }
    }

    function _hasFunction(address contract_, bytes memory data) internal view returns (bool) {
        (bool success, ) = contract_.staticcall(data);
        return success;
    }
}
