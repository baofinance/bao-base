// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IOwnable} from "@bao/interfaces/IOwnable.sol";
import {Token} from "@bao/Token.sol";

/// @title TokenHolderTestBase
/// @notice Reusable behaviour suite for any contract that adopts the TokenHolder / TokenHolder_v2 mixin.
///         Override `_tokenHolderTarget` (the deployed holder, owned by this test contract), `_tokenHolderSweepToken`
///         (a mintable MockERC20 the holder does not otherwise hold), and `_tokenHolderNonOwner` (an address that
///         does not own the holder); inherit the owner-gated recovery, transfer, and bad-input tests. Covers the
///         default `_checkSweeper` (owner-only) wiring - a contract that overrides `_checkSweeper` to a role, or
///         `_sweep` to cap the amount, keeps these for its unaffected paths and writes its own tests for the override.
abstract contract TokenHolderTestBase is Test {
    /// @dev The deployed TokenHolder (proxy) under test, owned by this test contract.
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

    /// @notice a specific amount sweeps exactly that; more than held reverts on the transfer; max sweeps the remainder.
    function test_tokenHolder_sweep_partialOverAndFull() public {
        address holder = _tokenHolderTarget();
        address token = _tokenHolderSweepToken();
        address receiver = _tokenHolderNonOwner();
        MockERC20(token).mint(holder, 3 ether);

        // a specific partial amount transfers exactly that
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(holder, receiver, 1 ether);
        ITokenHolder(holder).sweep(token, 1 ether, receiver);
        assertEq(IERC20(token).balanceOf(receiver), 1 ether);
        assertEq(IERC20(token).balanceOf(holder), 2 ether);

        // requesting more than held passes the request through allOf, so the transfer reverts
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 2 ether, 3 ether)
        );
        ITokenHolder(holder).sweep(token, 3 ether, receiver);
        assertEq(IERC20(token).balanceOf(holder), 2 ether);

        // max sweeps the whole remaining balance
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(holder, receiver, 2 ether);
        ITokenHolder(holder).sweep(token, type(uint256).max, receiver);
        assertEq(IERC20(token).balanceOf(receiver), 3 ether);
        assertEq(IERC20(token).balanceOf(holder), 0);
    }

    /// @notice a zero input amount reverts ZeroInputBalance.
    function test_tokenHolder_sweep_zeroAmount_reverts() public {
        address holder = _tokenHolderTarget();
        address token = _tokenHolderSweepToken();
        address receiver = _tokenHolderNonOwner();
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, token));
        ITokenHolder(holder).sweep(token, 0, receiver);
    }

    /// @notice a zero receiver reverts ZeroAddress.
    function test_tokenHolder_sweep_zeroReceiver_reverts() public {
        address holder = _tokenHolderTarget();
        address token = _tokenHolderSweepToken();
        vm.expectRevert(Token.ZeroAddress.selector);
        ITokenHolder(holder).sweep(token, 1 ether, address(0));
    }
}
