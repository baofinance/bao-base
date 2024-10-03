// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IOwnable } from "@bao/interfaces/IOwnableRoles.sol";
import { Token } from "@bao/Token.sol";
import { TokenHolder } from "@bao/TokenHolder.sol";

import { Deployed } from "@bao/Deployed.sol";

contract DerivedTokenHolder is Initializable, TokenHolder {
    function initialize(address owner) public initializer {
        _initializeOwner(owner);
    }
}

contract Test_TokenHolder is Test {
    using SafeERC20 for IERC20;
    address token1 = Deployed.BaoUSD;
    address token2 = Deployed.wstETH;
    address tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token

    address bonusReceiver;
    address owner;

    DerivedTokenHolder tokenOwner;
    bytes32 ownerRole = 0;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);
        tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token
        bonusReceiver = vm.createWallet("bonusReceiver").addr;
        owner = vm.createWallet("owner").addr;

        tokenOwner = new DerivedTokenHolder();
        tokenOwner.initialize(owner);
    }

    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == address(0)) {
            return who.balance;
        } else {
            return IERC20(token).balanceOf(who);
        }
    }

    function _deal(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(to, amount);
        } else {
            deal(token, to, amount);
        }
    }

    function test_access() public {
        // not anyone can withdraw funds
        vm.expectRevert(IOwnable.Unauthorized.selector);
        tokenOwner.sweep(token1, 1 ether, bonusReceiver);
    }

    function test_transfer() public {
        // we assume all tokens are ERC20
        address[2] memory tokens = [token2, token1];
        for (uint i = 0; i < tokens.length; i++) {
            // make sure nothing has a balance of any bonus tokens
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 0);

            // when none
            // BaoUSD is one minimalist token!
            if (tokens[i] == Deployed.BaoUSD) vm.expectRevert("SafeMath: subtraction underflow");
            else vm.expectRevert("ERC20: transfer amount exceeds balance");
            vm.prank(owner);
            tokenOwner.sweep(tokens[i], 1 ether, bonusReceiver);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 0 ether);

            // add some funds - anyone can do this
            deal(tokens[i], address(tokenOwner), 3 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 3 ether);

            // request less than some
            vm.expectEmit(true, true, true, true);
            emit IERC20.Transfer(address(tokenOwner), bonusReceiver, 1 ether);
            vm.prank(owner);
            tokenOwner.sweep(tokens[i], 1 ether, bonusReceiver);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 1 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 2 ether);

            // request more than some
            if (tokens[i] == Deployed.BaoUSD) vm.expectRevert("SafeMath: subtraction underflow");
            else vm.expectRevert("ERC20: transfer amount exceeds balance");
            vm.prank(owner);
            tokenOwner.sweep(tokens[i], 3 ether, bonusReceiver);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 1 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 2 ether);

            // withdraw it all
            // withdraw
            vm.expectEmit(true, true, true, true);
            emit IERC20.Transfer(address(tokenOwner), bonusReceiver, 2 ether);
            vm.prank(owner);
            tokenOwner.sweep(tokens[i], type(uint256).max, bonusReceiver);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 3 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 0 ether);
        }
    }

    // TODO: create a test file for Token and TokenHolder and test it (below and above0 there, once for all derived classes
    function test_badInputs() public {
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, token1));
        vm.prank(owner);
        tokenOwner.sweep(token1, 0 ether, address(this));

        vm.expectRevert(Token.ZeroAddress.selector);
        vm.prank(owner);
        tokenOwner.sweep(token1, 1 ether, address(0));
    }
}
