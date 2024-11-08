// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

contract DerivedBaoOwnable is BaoOwnable {
    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function pendingOwner() public view returns (address pendingOwner_) {
        assembly ("memory-safe") {
            pendingOwner_ := sload(_PENDING_SLOT)
        }
    }

    function pendingExpiry() public view returns (uint64 expiry) {
        assembly ("memory-safe") {
            expiry := shr(192, sload(_PENDING_SLOT))
        }
    }

    function protected() public onlyOwner {}
}

contract TestBaoOwnableOnly is Test {
    address ownable;
    address owner;
    address user;

    function setUp() public virtual {
        owner = vm.createWallet("owner").addr;
        user = vm.createWallet("user").addr;

        ownable = address(new DerivedBaoOwnable());
    }

    function _initialize(address owner_) internal {
        assertEq(IBaoOwnable(ownable).owner(), address(0));
        assertEq(DerivedBaoOwnable(ownable).pendingOwner(), address(0));
        assertEq(DerivedBaoOwnable(ownable).pendingExpiry(), 0);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(owner_);
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        assertEq(DerivedBaoOwnable(ownable).pendingOwner(), owner_);
        assertEq(DerivedBaoOwnable(ownable).pendingExpiry(), block.timestamp + 3600);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner_);
        IBaoOwnable(ownable).transferOwnership(owner_);
        assertEq(IBaoOwnable(ownable).owner(), owner_);
        assertEq(DerivedBaoOwnable(ownable).pendingOwner(), address(0));
        assertEq(DerivedBaoOwnable(ownable).pendingExpiry(), 0);
    }

    function test_initialize(uint64 start) public {
        start = uint64(bound(start, 1, type(uint64).max - 52 weeks));

        vm.warp(start);
        // member data
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);

        // pending is all zeros
        assertEq(DerivedBaoOwnable(ownable).pendingOwner(), address(0));
        assertEq(DerivedBaoOwnable(ownable).pendingExpiry(), 0);

        // can initialise to an owner
        _initialize(owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(user);
    }

    function test_introspection() public view virtual {
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnable).interfaceId));
    }

    function test_initializeTimeoutJustBefore() public {
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        skip(3600);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_initializeTimeoutAfter() public {
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        skip(3601);

        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));
    }

    function test_owner() public {
        // can initialise to an owner, who is deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // call a function that fails unless done by an owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnable(ownable).transferOwnership(user);

        // complete the transfer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // the have the owner complete on a null pending
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);
    }

    function test_onlyOwner() public {
        _initialize(owner);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoOwnable(ownable).protected();

        vm.prank(owner);
        DerivedBaoOwnable(ownable).protected();
    }

    function test_reinitAfterTransfer() public {
        _initialize(owner);

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_reinitAfterRenounce() public {
        _initialize(address(0));

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function test_transfer1stepZero() public {
        _initialize(address(0));
    }

    function test_transfer1stepThis() public {
        _initialize(address(this));
    }

    function test_transfer1stepAnother() public {
        _initialize(user);
    }

    function test_deployNoTransfer() public {
        // initialise to target owner immediately
        vm.prank(owner);
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't renounce ownership
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_deployWithTransfer() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(owner);

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);

        // no-one can transfer ownership (one-step)
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnable(ownable).transferOwnership(user);

        // but deployer can, if they are the owner, transfer ownership
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // deployer can't transfer ownership twice
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't use one-step transfer
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_transferOwnership() public {
        _initialize(user);

        // cannot transfer after an hour
        skip(1 hours + 1 seconds);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(user);
    }

    function test_deployWithRenounce() public {
        // owner is initially set to the deployer
        _initialize(address(0));

        // deployer can't transfer ownership twice
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function test_oneStepDisabledTransfer() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // future owner can't renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // future owner can't transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // deployer can transfer to owner
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_oneStepDisabledRenounce() public {
        _initialize(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        //  can't transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't even request a transfer or a renunciation
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);
    }
}
