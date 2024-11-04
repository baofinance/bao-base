// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC5313 } from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";
import { BaoOwnable } from "@bao/BaoOwnable.sol";

contract DerivedBaoOwnable is BaoOwnable {
    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function ownershipTransferValidFor() public pure returns (uint64) {
        return 4 days;
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
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferInitiated(owner_);
        DerivedBaoOwnable(ownable).initialize(owner_);
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        _checkPending(owner_, block.timestamp, true, block.timestamp + 3600);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner_);
        IBaoOwnable(ownable).transferOwnership(owner_);
        assertEq(IBaoOwnable(ownable).owner(), owner_);
    }

    function test_initialize(uint64 start) public {
        start = uint64(bound(start, 1, type(uint64).max - 52 weeks));

        vm.warp(start);
        // member data
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);

        // can initialise to an owner
        _initialize(owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(user);

        // introspection
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnable).interfaceId));
    }

    function test_initializeTimeoutJustBefore() public {
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        _checkPending(owner, block.timestamp, true, block.timestamp + 3600);

        skip(3600);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_initializeTimeoutAfter() public {
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        _checkPending(owner, block.timestamp, true, block.timestamp + 3600);

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

        // transfer two-step back to deployer to see if there are any residuals
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipTransfer(address(this));
        IBaoOwnable(ownable).validateOwnershipTransfer();
        // need to add in pause time
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // now the deployer can't one-step transfer
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // nor can the deployer renounce
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
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

        // can't even request a transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).initiateOwnershipTransfer(owner);

        // can't even request a transfer or a renunciation
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);
    }

    function _checkPending(
        address pendingOwner,
        uint256 acceptExpiryOrCompletePause,
        bool validated,
        uint256 transferExpiry
    ) private view {
        (
            address e_pendingOwner,
            uint64 e_acceptExpiryOrCompletePause,
            bool e_validated,
            uint64 e_transferExpiry
        ) = IBaoOwnable(ownable).pending();
        assertEq(pendingOwner, e_pendingOwner, "pendingOwner");
        assertEq(acceptExpiryOrCompletePause, e_acceptExpiryOrCompletePause, "acceptExpiryOrCompletePause");
        assertEq(validated, e_validated, "validated");
        assertEq(transferExpiry, e_transferExpiry, "transferExpiry");
    }

    function _pendingExpiry() private view returns (uint64 expiry) {
        (, , , expiry) = IBaoOwnable(ownable).pending();
    }

    function _pendingPauseTo() private view returns (uint64 pauseTo) {
        (, pauseTo, , ) = IBaoOwnable(ownable).pending();
    }

    function _pendingOwner() private view returns (address pendingOwner_) {
        (pendingOwner_, , , ) = IBaoOwnable(ownable).pending();
    }

    function _pendingValidated() private view returns (bool validated) {
        (, , validated, ) = IBaoOwnable(ownable).pending();
    }

    function _checkSuccessful_initiateOwnershipTransfer(address by, address to, bool takeOver) private {
        // TODO: add test cases for address(0)
        // valid initiate - check events and updated values
        assertEq(by, IBaoOwnable(ownable).owner());

        // only do these checks if it is a pristine initiate, not a takover initiate
        if (!takeOver) {
            assertEq(_pendingExpiry(), 0);
            assertEq(_pendingOwner(), address(0));
            assertEq(_pendingValidated(), false);
            assertEq(_pendingPauseTo(), 0);
        }
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferInitiated(to);
        vm.prank(by);
        IBaoOwnable(ownable).initiateOwnershipTransfer(to);
        assertEq(_pendingExpiry(), block.timestamp + DerivedBaoOwnable(ownable).ownershipTransferValidFor());
        assertEq(_pendingOwner(), to);
        assertEq(_pendingValidated(), to == address(0) ? true : false);
        assertEq(_pendingPauseTo(), block.timestamp + DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2);
    }

    function test_initiateTransfer() public {
        // owner is initially set to the owner
        _initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // cannot initiate a transfer unless you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).initiateOwnershipTransfer(user);

        // initiating transfers just overwrites any previous one
        // to someone
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
        // even to the owner
        _checkSuccessful_initiateOwnershipTransfer(owner, owner, true);
        // before accept
        _checkSuccessful_initiateOwnershipTransfer(owner, address(this), true);
        // after the accept
        IBaoOwnable(ownable).validateOwnershipTransfer();
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
    }

    function _checkSuccessful_validateOwnershipTransfer(address by) private {
        uint64 expiry = _pendingExpiry();
        assertLe(block.timestamp, _pendingPauseTo());
        assertEq(_pendingOwner(), by);
        assertEq(_pendingValidated(), false);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferValidated(by);
        vm.prank(by);
        IBaoOwnable(ownable).validateOwnershipTransfer();
        assertEq(_pendingExpiry(), expiry);
        assertEq(_pendingOwner(), by);
        assertEq(_pendingValidated(), true);
    }

    function test_acceptTransfer() public {
        // TODO: check for a renounce
        // owner is initially set to the owner
        _initialize(owner);

        // can't accept uness there's been an initiation
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).validateOwnershipTransfer();

        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        // can't accept unless you are the pending Owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).validateOwnershipTransfer();
        // not even the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).validateOwnershipTransfer();

        // can accept immediately
        _checkSuccessful_validateOwnershipTransfer(user);

        // can't accept twice
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnable(ownable).validateOwnershipTransfer();

        // can accept up to a time
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2);
        _checkSuccessful_validateOwnershipTransfer(user);

        // can't accept after a time
        _checkSuccessful_initiateOwnershipTransfer(owner, user, true);
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(user);
        IBaoOwnable(ownable).validateOwnershipTransfer();
    }

    // TODO: check there is no difference for a two step deployment
    // TODO: check a two-step deployment times out after 1 hour

    function _checkSuccessful_transferOwnership(address by, address to) private {
        assertEq(by, IBaoOwnable(ownable).owner());
        assertGt(block.timestamp, _pendingPauseTo());
        assertLt(block.timestamp, _pendingExpiry());

        assertEq(_pendingOwner(), to);
        assertEq(_pendingValidated(), true);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(by, to);
        vm.prank(by);
        IBaoOwnable(ownable).transferOwnership(to);
        _checkPending(address(0), 0, false, 0);
    }

    function test_completeTransfer() public {
        // owner is initially set to the owner
        _initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // successful initiate
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        // cannot complete unless there has been an accept
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);

        // cannot complete unless the pause period has passed too
        _checkSuccessful_validateOwnershipTransfer(user);
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);

        // can complete when both have passed
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);

        // need owner to complete
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(user);

        _checkSuccessful_transferOwnership(owner, user);

        // need to check an accept is needed
        _checkSuccessful_initiateOwnershipTransfer(user, owner, false);
        // cannot complete unless the pause period has passed
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(user);
        IBaoOwnable(ownable).transferOwnership(owner);
    }

    function _cancelTransfer(address canceller) private {
        _initialize(owner);

        // only owner or recipient can cancel
        // if it's not in-flight then
        assertTrue(canceller == user || canceller == IBaoOwnable(ownable).owner(), "canceller owner or pending");

        // then only if there's an in-flight transfer
        if (canceller != owner) vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(canceller);
        IBaoOwnable(ownable).cancelOwnershipTransfer();

        // start an actual transfer then cancel immediately
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        vm.prank(canceller);
        IBaoOwnable(ownable).cancelOwnershipTransfer();

        // start another - cancel after accept but before pause
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        _checkSuccessful_validateOwnershipTransfer(user);
        vm.prank(canceller);
        IBaoOwnable(ownable).cancelOwnershipTransfer();

        // start another - cancel after pause but before accept
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);
        vm.prank(canceller);
        IBaoOwnable(ownable).cancelOwnershipTransfer();

        // start another - cancel after accept and after pause
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        _checkSuccessful_validateOwnershipTransfer(user);
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);
        vm.prank(canceller);
        IBaoOwnable(ownable).cancelOwnershipTransfer();

        // start another just to make sure the last cancel succeeded
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
    }

    function test_cancelTransferByOther() public {
        _initialize(owner);

        assertTrue(
            address(this) != _pendingOwner() && address(this) != IBaoOwnable(ownable).owner(),
            "owner or pending"
        );

        // without in-flight - don't know if it's authorized
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).cancelOwnershipTransfer();

        // with in-flight
        _checkSuccessful_initiateOwnershipTransfer(owner, user, false);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).cancelOwnershipTransfer();
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
        assertEq(_pendingExpiry(), 0);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipTransfer(toAddress);
        assertEq(_pendingExpiry(), block.timestamp + DerivedBaoOwnable(ownable).ownershipTransferValidFor());

        // cancel
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferCanceled(toAddress);
        vm.prank(owner);
        IBaoOwnable(ownable).cancelOwnershipTransfer();
    }

    function _twoStepTransferTimingCancel2nd(address toAddress) private {
        // owner is initially set to the owner
        _initialize(owner);

        assertTrue(toAddress == user || toAddress == address(0));

        // transfer two-step to this
        assertEq(_pendingExpiry(), 0);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipTransfer(toAddress);
        assertEq(_pendingExpiry(), block.timestamp + DerivedBaoOwnable(ownable).ownershipTransferValidFor());

        // should be acceptable now
        if (toAddress == user) {
            vm.prank(user);
            IBaoOwnable(ownable).validateOwnershipTransfer();
        }
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2);

        // cancel
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferCanceled(toAddress);
        vm.prank(owner);
        IBaoOwnable(ownable).cancelOwnershipTransfer();
    }

    function _twoStepTransferTimingComplete(address toAddress) private {
        // owner is initially set to the owner
        _initialize(owner);

        assertTrue(toAddress == user || toAddress == address(0));

        // transfer two-step to this
        assertEq(_pendingExpiry(), 0);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipTransfer(toAddress);
        assertEq(_pendingExpiry(), block.timestamp + DerivedBaoOwnable(ownable).ownershipTransferValidFor());

        // should be acceptable now
        if (toAddress == user) {
            vm.prank(user);
            IBaoOwnable(ownable).validateOwnershipTransfer();
        }
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);

        // complete requester
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(toAddress);
        assertEq(IBaoOwnable(ownable).owner(), toAddress);
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
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // only owner can complete
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't renounce unless there's a request
        assertEq(_pendingExpiry(), 0);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // only owner can renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).initiateOwnershipTransfer(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);
        assertEq(_pendingExpiry(), 0);

        // renounce two-step
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferInitiated(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipTransfer(address(0));
        uint256 expiry = _pendingExpiry();
        assertNotEq(expiry, 0, "non-zero expiry");
        assertEq(IBaoOwnable(ownable).owner(), owner, "requesting doesn't do the transfer");

        // multiple requests are allowed
        skip(1 hours);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferInitiated(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipTransfer(address(0));
        assertEq(expiry + 1 hours, _pendingExpiry());

        // can't complete requester yet
        vm.expectRevert(IBaoOwnable.CannotCompleteTransfer.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertNotEq(_pendingExpiry(), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can complete, now, by rolling forward half the time
        skip(DerivedBaoOwnable(ownable).ownershipTransferValidFor() / 2 + 1);

        // and only if you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertNotEq(_pendingExpiry(), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // actually complete it!
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(owner, address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(_pendingExpiry(), 0);
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }
}
