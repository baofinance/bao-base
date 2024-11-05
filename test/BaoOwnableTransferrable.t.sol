// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC5313 } from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IBaoOwnableTransferrable } from "@bao/interfaces/IBaoOwnableTransferrable.sol";
import { BaoOwnableTransferrable } from "@bao/BaoOwnableTransferrable.sol";

contract DerivedBaoOwnableTransferrable is BaoOwnableTransferrable {
    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function protected() public onlyOwner {}
}

contract TestBaoOwnableTransferrableOnly is Test {
    address ownable;
    address owner;
    address user;

    function setUp() public virtual {
        owner = vm.createWallet("owner").addr;
        user = vm.createWallet("user").addr;

        ownable = address(new DerivedBaoOwnableTransferrable());
    }

    function _initialize(address owner_) internal {
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferInitiated(owner_);
        DerivedBaoOwnableTransferrable(ownable).initialize(owner_);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));
        _checkPending(owner_, block.timestamp, true, block.timestamp + 3600);

        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(this), owner_);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner_);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner_);
    }

    function test_initialize(uint64 start) public {
        start = uint64(bound(start, 1, type(uint64).max - 52 weeks));

        vm.warp(start);
        // member data
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);

        // can initialise to an owner
        _initialize(owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnableTransferrable.AlreadyInitialized.selector);
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnableTransferrable.AlreadyInitialized.selector);
        DerivedBaoOwnableTransferrable(ownable).initialize(user);

        // introspection
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnableTransferrable).interfaceId));
    }

    function test_initializeTimeoutJustBefore() public {
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));
        _checkPending(owner, block.timestamp, true, block.timestamp + 3600);

        skip(3600);

        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(this), owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);
    }

    function test_initializeTimeoutAfter() public {
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));
        _checkPending(owner, block.timestamp, true, block.timestamp + 3600);

        skip(3601);

        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));
    }

    function test_owner() public {
        // can initialise to an owner, who is deployer
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));

        // call a function that fails unless done by an owner
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);

        // complete the transfer
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(this), owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // the have the owner complete on a null pending
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);
    }

    function test_onlyOwner() public {
        _initialize(owner);

        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        DerivedBaoOwnableTransferrable(ownable).protected();

        vm.prank(owner);
        DerivedBaoOwnableTransferrable(ownable).protected();
    }

    function test_reinitAfterTransfer() public {
        _initialize(owner);

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnableTransferrable.AlreadyInitialized.selector);
        DerivedBaoOwnableTransferrable(ownable).initialize(address(this));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);
    }

    function test_reinitAfterRenounce() public {
        _initialize(address(0));

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnableTransferrable.AlreadyInitialized.selector);
        DerivedBaoOwnableTransferrable(ownable).initialize(address(this));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));
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
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // owner can't renounce ownership
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);
    }

    function test_deployWithTransfer() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);

        // no-one can transfer ownership (one-step)
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);

        // but deployer can, if they are the owner, transfer ownership
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(this), owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // deployer can't transfer ownership twice
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // owner can't use one-step transfer
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);
    }

    function test_transferOwnership() public {
        _initialize(user);

        // cannot transfer after an hour
        skip(1 hours + 1 seconds);
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);
    }

    function test_deployWithRenounce() public {
        // owner is initially set to the deployer
        _initialize(address(0));

        // deployer can't transfer ownership twice
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));
    }

    function test_oneStepDisabledTransfer() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnableTransferrable(ownable).initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));

        // future owner can't renounce
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));

        // future owner can't transfer
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));

        // deployer can transfer to owner
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // transfer two-step back to deployer to see if there are any residuals
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(address(this));
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
        // need to add in pause time
        skip(4 days / 2 + 1);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(this));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));

        // now the deployer can't one-step transfer
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));

        // nor can the deployer renounce
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(this));
    }

    function test_oneStepDisabledRenounce() public {
        _initialize(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));

        // can't renounce
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));

        //  can't transfer
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));

        // can't even request a transfer
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(owner);

        // can't even request a transfer or a renunciation
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
    }

    function _checkPending(
        address pendingOwner,
        uint256 validateExpiryOrPause,
        bool validated,
        uint256 transferExpiry
    ) private view {
        address e_pendingOwner = IBaoOwnableTransferrable(ownable).pendingOwner();
        uint64 e_validateExpiryOrPause = IBaoOwnableTransferrable(ownable).pendingValidateExpiryOrPause();
        bool e_validated = IBaoOwnableTransferrable(ownable).pendingValidated();
        uint64 e_expiry = IBaoOwnableTransferrable(ownable).pendingExpiry();

        assertEq(pendingOwner, e_pendingOwner, "pendingOwner");
        assertEq(validateExpiryOrPause, e_validateExpiryOrPause, "validateExpiryOrRenouncePause");
        assertEq(validated, e_validated, "validated");
        assertEq(transferExpiry, e_expiry, "transferExpiry");
    }

    function _checkSuccessful_initiateOwnershipTransfer(address by, address to, bool takeOver) private {
        // TODO: add test cases for address(0)
        // valid initiate - check events and updated values
        assertEq(by, IBaoOwnableTransferrable(ownable).owner());

        // only do these checks if it is a pristine initiate, not a takover initiate
        if (!takeOver) {
            _checkPending(address(0), 0, false, 0);
        }
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferInitiated(to);
        vm.prank(by);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(to);
        _checkPending(to, block.timestamp + 4 days / 2, to == address(0) ? true : false, block.timestamp + 4 days);
    }

    function test_initiateTransfer() public {
        // owner is initially set to the owner
        _initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // cannot initiate a transfer unless you're the owner
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(user);

        // initiating transfers just overwrites any previous one
        // to someone
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
        // even to the owner
        _checkSuccessful_initiateOwnershipTransfer(owner, owner, true);
        // before validate
        _checkSuccessful_initiateOwnershipTransfer(owner, address(this), true);
        // after the validate
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
    }

    function _checkSuccessful_validateOwnershipTransfer(address by) private {
        uint64 expiry = IBaoOwnableTransferrable(ownable).pendingExpiry();
        assertLe(block.timestamp, IBaoOwnableTransferrable(ownable).pendingValidateExpiryOrPause());
        assertEq(IBaoOwnableTransferrable(ownable).pendingOwner(), by);
        assertEq(IBaoOwnableTransferrable(ownable).pendingValidated(), false);
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferValidated(by);
        vm.prank(by);
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), expiry);
        assertEq(IBaoOwnableTransferrable(ownable).pendingOwner(), by);
        assertEq(IBaoOwnableTransferrable(ownable).pendingValidated(), true);
    }

    function test_validateTransfer() public {
        // TODO: check for a renounce
        // owner is initially set to the owner
        _initialize(owner);

        // can't validate uness there's been an initiation
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();

        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        // can't validate unless you are the pending Owner
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
        // not even the owner
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();

        // can validate immediately
        _checkSuccessful_validateOwnershipTransfer(user);

        // can't validate twice
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();

        // can validate up to a time
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
        skip(4 days / 2);
        _checkSuccessful_validateOwnershipTransfer(user);

        // can't validate after a time
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
        skip(4 days / 2 + 1);
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
    }

    // TODO: check there is no difference for a two step deployment
    // TODO: check a two-step deployment times out after 1 hour

    function _checkSuccessful_transferOwnership(address by, address to) private {
        assertEq(by, IBaoOwnableTransferrable(ownable).owner());
        assertGt(block.timestamp, IBaoOwnableTransferrable(ownable).pendingValidateExpiryOrPause());
        assertLt(block.timestamp, IBaoOwnableTransferrable(ownable).pendingExpiry());

        assertEq(IBaoOwnableTransferrable(ownable).pendingOwner(), to);
        assertEq(IBaoOwnableTransferrable(ownable).pendingValidated(), true);
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(by, to);
        vm.prank(by);
        IBaoOwnableTransferrable(ownable).transferOwnership(to);
        _checkPending(address(0), 0, false, 0);
    }

    function test_completeTransfer() public {
        // owner is initially set to the owner
        _initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // successful initiate
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        // cannot complete unless there has been an validate
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);

        // cannot complete unless the pause period has passed too
        _checkSuccessful_validateOwnershipTransfer(user);
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);

        // can complete when both have passed
        skip(4 days / 2 + 1);

        // need owner to complete
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(user);

        _checkSuccessful_transferOwnership(owner, user);

        // need to check an validate is needed
        _checkSuccessful_initiateOwnershipTransfer(user, owner, false);
        // cannot complete unless the pause period has passed
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(user);
        IBaoOwnableTransferrable(ownable).transferOwnership(owner);
    }

    function _cancelTransfer(address canceller) private {
        _initialize(owner);

        // only owner or recipient can cancel
        // if it's not in-flight then
        assertTrue(
            canceller == user || canceller == IBaoOwnableTransferrable(ownable).owner(),
            "canceller owner or pending"
        );

        // then only if there's an in-flight transfer
        if (canceller != owner) vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(canceller);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();

        // start an actual transfer then cancel immediately
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        vm.prank(canceller);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();

        // start another - cancel after validate but before pause
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        _checkSuccessful_validateOwnershipTransfer(user);
        vm.prank(canceller);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();

        // start another - cancel after pause but before validate
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        skip(4 days / 2 + 1);
        vm.prank(canceller);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();

        // start another - cancel after validate and after pause
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        _checkSuccessful_validateOwnershipTransfer(user);
        skip(4 days / 2 + 1);
        vm.prank(canceller);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();

        // start another just to make sure the last cancel succeeded
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
    }

    function test_cancelTransferByOther() public {
        _initialize(owner);

        assertTrue(
            address(this) != IBaoOwnableTransferrable(ownable).pendingOwner() &&
                address(this) != IBaoOwnableTransferrable(ownable).owner(),
            "owner or pending"
        );

        // without in-flight - don't know if it's authorized
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();

        // with in-flight
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();
    }

    function test_cancelTransferByOwner() public {
        _cancelTransfer(owner);
    }

    function test_cancelTransferByRecipient() public {
        _cancelTransfer(user);
    }

    function _twoStepTransferTimingCancel1st(address toAddress) private {
        // owner is initially set to the owner
        _initialize(owner);

        assertTrue(toAddress == user || toAddress == address(0));

        // transfer two-step to
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(toAddress);
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), block.timestamp + 4 days);

        // cancel
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferCanceled(toAddress);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();
    }

    function _twoStepTransferTimingCancel2nd(address toAddress) private {
        // owner is initially set to the owner
        _initialize(owner);

        assertTrue(toAddress == user || toAddress == address(0));

        // transfer two-step to this
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(toAddress);
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), block.timestamp + 4 days);

        // should be validateable now
        if (toAddress == user) {
            vm.prank(user);
            IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
        }
        skip(4 days / 2);

        // cancel
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferCanceled(toAddress);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).cancelOwnershipTransfer();
    }

    function _twoStepTransferTimingComplete(address toAddress) private {
        // owner is initially set to the owner
        _initialize(owner);

        assertTrue(toAddress == user || toAddress == address(0));

        // transfer two-step to this
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(toAddress);
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), block.timestamp + 4 days);

        // should be validateable now
        if (toAddress == user) {
            vm.prank(user);
            IBaoOwnableTransferrable(ownable).validateOwnershipTransfer();
        }
        skip(4 days / 2 + 1);

        // complete requester
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(toAddress);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), toAddress);
    }

    function test_twoStepTransferTimingCancel1stUser() public {
        _twoStepTransferTimingCancel1st(user);
    }

    function test_twoStepTransferTimingCancel1st0() public {
        _twoStepTransferTimingCancel1st(address(0));
    }

    function test_twoStepTransferTimingCancel2ndUser() public {
        _twoStepTransferTimingCancel2nd(user);
    }

    function test_twoStepTransferTimingCancel2nd0() public {
        _twoStepTransferTimingCancel2nd(address(0));
    }

    function test_twoStepTransferTimingCompleteUser() public {
        _twoStepTransferTimingComplete(user);
    }

    function test_twoStepTransferTimingComplete0() public {
        _twoStepTransferTimingComplete(address(0));
    }

    function test_twoStepRenounceSimple() public {
        vm.skip(true);
        // owner is initially set to the owner
        _initialize(owner);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // only owner can complete
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // can't renounce unless there's a request
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // only owner can renounce
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);

        // renounce two-step
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferInitiated(address(0));
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(address(0));
        uint256 expiry = IBaoOwnableTransferrable(ownable).pendingExpiry();
        assertNotEq(expiry, 0, "non-zero expiry");
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner, "requesting doesn't do the transfer");

        // multiple requests are allowed
        skip(1 hours);
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferInitiated(address(0));
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).initiateOwnershipTransfer(address(0));
        assertEq(expiry + 1 hours, IBaoOwnableTransferrable(ownable).pendingExpiry());

        // can't complete requester yet
        vm.expectRevert(IBaoOwnableTransferrable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertNotEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // can complete, now, by rolling forward half the time
        skip(4 days / 2 + 1);

        // and only if you're the owner
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertNotEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), owner);

        // actually complete it!
        vm.expectEmit();
        emit IBaoOwnableTransferrable.OwnershipTransferred(owner, address(0));
        vm.prank(owner);
        IBaoOwnableTransferrable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnableTransferrable(ownable).pendingExpiry(), 0);
        assertEq(IBaoOwnableTransferrable(ownable).owner(), address(0));
    }
}