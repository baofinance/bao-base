// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnableV2} from "@bao/interfaces/IBaoOwnableV2.sol";
import {BaoOwnableV2} from "@bao/BaoOwnableV2.sol";

contract DerivedBaoOwnableV2 is BaoOwnableV2 {
    // constructor sets up the owner
    constructor(address owner) BaoOwnableV2(owner) {}

    function protected() public onlyOwner {}
}

contract TestBaoOwnableV2Only is Test {
    address owner;
    address user;

    function setUp() public virtual {
        owner = vm.createWallet("owner").addr;
        user = vm.createWallet("user").addr;
    }

    function _initialize(address owner_) internal {
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableV2.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableV2.OwnershipTransferred(address(this), owner_);
        address ownable = address(new DerivedBaoOwnableV2(owner_));
        assertEq(IBaoOwnableV2(ownable).owner(), address(this));

        // move timestamop forward just short of the hour
        // console2.log("block.timestamp", block.timestamp);
        skip(3599);
        // console2.log("block.timestamp", block.timestamp);
        assertEq(IBaoOwnableV2(ownable).owner(), address(this));
        // now we trigger the transfer
        skip(1);
        // console2.log("block.timestamp", block.timestamp);
        assertEq(IBaoOwnableV2(ownable).owner(), owner_);
    }

    // function test_initialize(uint64 start) public {
    //     start = uint64(bound(start, 1, type(uint64).max - 52 weeks));

    //     vm.warp(start);
    //     // member data
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(0));

    //     // can't transfer ownership, there's no owner or deployer yet
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);

    //     // pending is all zeros
    //     assertEq(DerivedBaoOwnableV2(ownable).pendingOwner(), address(0));
    //     assertEq(DerivedBaoOwnableV2(ownable).pendingExpiry(), 0);

    //     // can initialise to an owner
    //     _initialize(owner);

    //     // can't initialise again
    //     vm.expectRevert(IBaoOwnableV2.AlreadyInitialized.selector);
    //     DerivedBaoOwnableV2(ownable).initialize(owner);

    //     // can't initialise again
    //     vm.expectRevert(IBaoOwnableV2.AlreadyInitialized.selector);
    //     DerivedBaoOwnableV2(ownable).initialize(user);
    // }

    function test_introspection() public virtual {
        address ownable = address(new DerivedBaoOwnableV2(address(0)));
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnableV2).interfaceId));
    }

    // function test_initializeTimeoutJustBefore() public {
    //     DerivedBaoOwnableV2(ownable).initialize(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));

    //     skip(3600);

    //     vm.expectEmit();
    //     emit IBaoOwnableV2.OwnershipTransferred(address(this), owner);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);
    // }

    // function test_initializeTimeoutAfter() public {
    //     DerivedBaoOwnableV2(ownable).initialize(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));

    //     skip(3601);

    //     vm.expectRevert(IBaoOwnableV2.CannotCompleteTransfer.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));
    // }

    // function test_owner() public {
    //     // can initialise to an owner, who is deployer
    //     vm.expectEmit();
    //     emit IBaoOwnableV2.OwnershipTransferred(address(0), address(this));
    //     DerivedBaoOwnableV2(ownable).initialize(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));

    //     // call a function that fails unless done by an owner
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     vm.prank(user);
    //     IBaoOwnableV2(ownable).transferOwnership(user);

    //     // complete the transfer
    //     vm.expectEmit();
    //     emit IBaoOwnableV2.OwnershipTransferred(address(this), owner);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);

    //     // the have the owner complete on a null pending
    //     vm.expectRevert(IBaoOwnableV2.CannotCompleteTransfer.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(user);
    // }

    function test_onlyOwner() public {
        address ownable = address(new DerivedBaoOwnableV2(owner));
        // this can call protected at the moment
        DerivedBaoOwnableV2(ownable).protected();

        // owner isn't owner yet
        vm.prank(owner);
        vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
        DerivedBaoOwnableV2(ownable).protected();

        skip(3600);
        // owner has now moved
        vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
        DerivedBaoOwnableV2(ownable).protected();

        vm.prank(owner);
        DerivedBaoOwnableV2(ownable).protected();
    }

    function test_onlyOwner0() public {
        address ownable = address(new DerivedBaoOwnableV2(address(0)));
        // this can call protected at the moment
        DerivedBaoOwnableV2(ownable).protected();
        assertEq(IBaoOwnableV2(ownable).owner(), address(this));

        skip(3600);
        // owner has now been removed
        vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
        DerivedBaoOwnableV2(ownable).protected();
        assertEq(IBaoOwnableV2(ownable).owner(), address(0));
    }

    // function test_reinitAfterTransfer() public {
    //     _initialize(owner);

    //     // can't initialise again after a transfer
    //     vm.expectRevert(IBaoOwnableV2.AlreadyInitialized.selector);
    //     DerivedBaoOwnableV2(ownable).initialize(address(this));
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);
    // }

    // function test_reinitAfterRenounce() public {
    //     _initialize(address(0));

    //     // can't initialise again after a transfer
    //     vm.expectRevert(IBaoOwnableV2.AlreadyInitialized.selector);
    //     DerivedBaoOwnableV2(ownable).initialize(address(this));
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(0));
    // }

    function test_transfer1stepZero() public {
        _initialize(address(0));
    }

    function test_transfer1stepThis() public {
        _initialize(address(this));
    }

    function test_transfer1stepAnother() public {
        _initialize(user);
    }

    // function test_deployNoTransfer() public {
    //     // initialise to target owner immediately
    //     vm.prank(owner);
    //     DerivedBaoOwnableV2(ownable).initialize(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);

    //     // owner can't transfer ownership (one-step)
    //     vm.expectRevert(IBaoOwnableV2.CannotCompleteTransfer.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(user);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);

    //     // owner can't renounce ownership
    //     vm.expectRevert(IBaoOwnableV2.CannotCompleteTransfer.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(address(0));
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);
    // }

    // function test_deployWithTransfer() public {
    //     // owner is initially set to the deployer
    //     vm.expectEmit();
    //     emit IBaoOwnableV2.OwnershipTransferred(address(0), address(this));
    //     DerivedBaoOwnableV2(ownable).initialize(owner);

    //     // owner can't transfer ownership (one-step)
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(user);

    //     // no-one can transfer ownership (one-step)
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     vm.prank(user);
    //     IBaoOwnableV2(ownable).transferOwnership(user);

    //     // but deployer can, if they are the owner, transfer ownership
    //     vm.expectEmit();
    //     emit IBaoOwnableV2.OwnershipTransferred(address(this), owner);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);

    //     // deployer can't transfer ownership twice
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);

    //     // owner can't use one-step transfer
    //     vm.expectRevert(IBaoOwnableV2.CannotCompleteTransfer.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(user);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);
    // }

    // function test_transferOwnership() public {
    //     _initialize(user);

    //     // cannot transfer after an hour
    //     skip(1 hours + 1 seconds);
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(user);
    // }

    // function test_deployWithRenounce() public {
    //     // owner is initially set to the deployer
    //     _initialize(address(0));

    //     // deployer can't transfer ownership twice
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(address(0));
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(0));
    // }

    // function test_oneStepDisabledTransfer() public {
    //     // owner is initially set to the deployer
    //     vm.expectEmit();
    //     emit IBaoOwnableV2.OwnershipTransferred(address(0), address(this));
    //     DerivedBaoOwnableV2(ownable).initialize(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));

    //     // future owner can't renounce
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(address(0));
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));

    //     // future owner can't transfer
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     vm.prank(owner);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(this));

    //     // deployer can transfer to owner
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), owner);
    // }

    // function test_oneStepDisabledRenounce() public {
    //     _initialize(address(0));
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(0));

    //     // can't renounce
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(address(0));
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(0));

    //     //  can't transfer
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    //     assertEq(IBaoOwnableV2(ownable).owner(), address(0));

    //     // can't even request a transfer or a renunciation
    //     vm.expectRevert(IBaoOwnableV2.Unauthorized.selector);
    //     IBaoOwnableV2(ownable).transferOwnership(owner);
    // }
}
