// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable_v2} from "@bao/interfaces/IBaoOwnable_v2.sol";
import {BaoOwnable_v2} from "@bao/BaoOwnable_v2.sol";

contract DerivedBaoOwnable_v2 is BaoOwnable_v2 {
    // constructor sets up the owner
    constructor(address owner, uint256 delay) BaoOwnable_v2(owner, delay) {}

    function protected() public onlyOwner {}

    function unprotected() public {}
}

contract TestBaoOwnable_v2Only is Test {
    address owner;
    address user;

    function setUp() public virtual {
        owner = makeAddr("owner");
        user = makeAddr("user");
    }

    function _initialize(address owner_, uint256 delay) internal {
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnable_v2.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnable_v2.OwnershipTransferred(address(this), owner_);
        address ownable = address(new DerivedBaoOwnable_v2(owner_, delay));

        if (delay > 0) {
            assertEq(IBaoOwnable_v2(ownable).owner(), address(this));

            // move timestamop forward just short of the hour
            // console2.log("block.timestamp", block.timestamp);
            skip(delay - 1);
            // console2.log("block.timestamp", block.timestamp);
            assertEq(IBaoOwnable_v2(ownable).owner(), address(this));
            // now we trigger the transfer
            skip(1);
        }
        // console2.log("block.timestamp", block.timestamp);
        assertEq(IBaoOwnable_v2(ownable).owner(), owner_);
    }

    function _introspectionOnly(address ownable) internal view {
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnable_v2).interfaceId));
    }

    function test_introspection() public virtual {
        address ownable = address(new DerivedBaoOwnable_v2(address(0), 0));
        _introspectionOnly(ownable);
    }

    function test_onlyOwner() public {
        address ownable = address(new DerivedBaoOwnable_v2(owner, 3600));
        // this can call protected at the moment
        DerivedBaoOwnable_v2(ownable).protected();
        DerivedBaoOwnable_v2(ownable).unprotected();

        // owner isn't owner yet
        vm.prank(owner);
        DerivedBaoOwnable_v2(ownable).unprotected();

        vm.prank(owner);
        vm.expectRevert(IBaoOwnable_v2.Unauthorized.selector);
        DerivedBaoOwnable_v2(ownable).protected();

        skip(3600);
        // owner has now moved
        DerivedBaoOwnable_v2(ownable).unprotected();

        vm.expectRevert(IBaoOwnable_v2.Unauthorized.selector);
        DerivedBaoOwnable_v2(ownable).protected();

        vm.prank(owner);
        DerivedBaoOwnable_v2(ownable).unprotected();

        vm.prank(owner);
        DerivedBaoOwnable_v2(ownable).protected();
    }

    function test_onlyOwner0() public {
        address ownable = address(new DerivedBaoOwnable_v2(address(0), 3600));
        // this can call protected at the moment
        DerivedBaoOwnable_v2(ownable).protected();
        assertEq(IBaoOwnable_v2(ownable).owner(), address(this));

        skip(3600);
        // owner has now been removed
        vm.expectRevert(IBaoOwnable_v2.Unauthorized.selector);
        DerivedBaoOwnable_v2(ownable).protected();
        assertEq(IBaoOwnable_v2(ownable).owner(), address(0));
    }

    function test_transfer1stepZero(uint256 delay) public {
        delay = bound(delay, 0, 1 weeks);
        _initialize(address(0), delay);
    }

    function test_transfer1stepThis(uint256 delay) public {
        delay = bound(delay, 0, 1 weeks);
        _initialize(address(this), delay);
    }

    function test_transfer1stepAnother(uint256 delay) public {
        delay = bound(delay, 0, 1 weeks);
        _initialize(user, delay);
    }
}
