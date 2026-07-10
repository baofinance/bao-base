// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IOwnable} from "@bao/interfaces/IOwnable.sol";

/// @title TokenHolderTestBase
/// @notice Reusable behaviour suite for any contract that adopts the TokenHolder mixin.
///         Override `_tokenHolderTarget` (the deployed holder), `_tokenHolderSweepToken`
///         (a mintable MockERC20), and `_tokenHolderNonOwner` (an address that does not
///         own the holder); inherit the owner-gated recovery tests. Covers the default
///         `_checkSweeper` (owner-only) wiring — a contract that overrides `_checkSweeper`
///         to a role writes its own gate test.
abstract contract TokenHolderTestBase is Test {
    /// @dev The deployed TokenHolder (proxy) under test.
    function _tokenHolderTarget() internal view virtual returns (address);

    /// @dev A mintable MockERC20 that can be sent to the holder and swept back out.
    function _tokenHolderSweepToken() internal view virtual returns (address);

    /// @dev An address that is NOT the owner/sweeper of the holder.
    function _tokenHolderNonOwner() internal view virtual returns (address);

    /// @notice Tokens sent to the holder by mistake are recoverable by the owner via sweep().
    function test_tokenHolder_sweep_recoversDonatedToken() public {
        address holder = _tokenHolderTarget();
        address token = _tokenHolderSweepToken();
        address receiver = _tokenHolderNonOwner();
        uint256 donation = 1 ether;
        MockERC20(token).mint(holder, donation);

        ITokenHolder(holder).sweep(token, donation, receiver);

        assertEq(IERC20(token).balanceOf(receiver), donation, "swept to receiver");
        assertEq(IERC20(token).balanceOf(holder), 0, "holder emptied");
    }

    /// @notice sweep() is owner-gated: a non-owner call reverts Unauthorized.
    function test_tokenHolder_sweep_calledByStranger_reverts() public {
        address holder = _tokenHolderTarget();
        address token = _tokenHolderSweepToken();
        address stranger = _tokenHolderNonOwner();
        uint256 donation = 1 ether;
        MockERC20(token).mint(holder, donation);

        vm.startPrank(stranger);
        vm.expectRevert(IOwnable.Unauthorized.selector);
        ITokenHolder(holder).sweep(token, donation, stranger);
        vm.stopPrank();
    }
}
