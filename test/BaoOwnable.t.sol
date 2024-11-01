// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";
import { BaoOwnable } from "@bao/BaoOwnable.sol";

contract DerivedBaoOwnable is BaoOwnable {
    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function ownershipHandoverValidFor() public pure returns (uint64) {
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

    // TODO: check initialisation to 0 as well as transferOwnership to 0 (same tests really)

    function test_init() public {
        // member data
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);

        // can initialise to an owner
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), owner);
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't initialise again
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // introspection
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnable).interfaceId));
    }

    function test_owner() public {
        // can initialise to an owner, who is deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // call a function that fails unless done by an owner
        vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(user);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(user);
    }

    function test_onlyOwner() public {
        DerivedBaoOwnable(ownable).initialize(owner);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoOwnable(ownable).protected();

        vm.prank(owner);
        DerivedBaoOwnable(ownable).protected();
    }

    function test_reinitAfterTransfer() public {
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_reinitAfterRenounce() public {
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), address(0));
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function test_transfer1stepZero() public {
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function test_transfer1step() public {
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_deployNoTransfer() public {
        // initialise to target owner immediately
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // deployer can't transfer ownership
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // deployer can't renounce ownership
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't renounce ownership
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_deployWithTransfer() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(address(this));

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
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't use one-step transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    function test_transferOwnership() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(address(this));

        // cannot transfer after an hour
        skip(1 hours + 1 seconds);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(user);
    }

    function test_deployWithRenounce() public {
        // owner is initially set to the deployer
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        DerivedBaoOwnable(ownable).initialize(address(this));

        // owner can't renounce ownership (one-step)
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));

        // deployer can renounce ownership
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), address(0));
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // deployer can't transfer ownership twice
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function test_oneStepDisabledTransfer() public {
        // owner is initially set to the deployer
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(this));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // transfer two-step back to deployer to see if there are any residuals
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(this));
        IBaoOwnable(ownable).acceptOwnershipHandover();
        // need to add in pause time
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // now the deployer can't one-step transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(user);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // nor can the deployer renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
    }

    function test_oneStepDisabledRenounce() public {
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        IBaoOwnable(ownable).transferOwnership(address(0));
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
        IBaoOwnable(ownable).initiateOwnershipHandover(owner);

        // can't even request a transfer or a renunciation
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(owner);
    }

    function _pendingStart(address ownable_) private view returns (uint64 start) {
        (, start) = IBaoOwnable(ownable_).pending();
    }

    function _pendingOwner(address ownable_) private view returns (address pendingOwner_) {
        (pendingOwner_, ) = IBaoOwnable(ownable_).pending();
    }

    function test_twoStepTransferSimple() public {
        // owner is initially set to the owner
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't accept unless you're the pending owner and there's none
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).acceptOwnershipHandover();

        // can't accept unless you're the owner or pending owner and there's none
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).cancelOwnershipHandover();

        // can't handover unless you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(user);

        // even for the owner, there must be an initiation
        vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // cannot initiate a handover unless you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).initiateOwnershipHandover(user);

        // cannot initiate a handover to current owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(owner);

        // transfer two-step to this
        assertEq(_pendingStart(ownable), 0);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverInitiated(address(this));
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(this));
        assertEq(_pendingOwner(ownable), address(this));
        uint64 start = _pendingStart(ownable);
        assertEq(start, block.timestamp, "non-zero start");
        assertEq(IBaoOwnable(ownable).owner(), owner, "requesting doesn't do the transfer");

        skip(1 minutes);
        // multiple requests are allowed, but they override each other
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverInitiated(user);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(user);
        assertGt(block.timestamp, start);
        assertEq(_pendingStart(ownable), block.timestamp, "both 1 non-zero expiry");

        // multiple requests are allowed to the same address, just delays it
        skip(1 hours);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverInitiated(user);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(user);
        assertEq(_pendingStart(ownable), block.timestamp);

        // can't complete yet
        vm.expectRevert(IBaoOwnable.CannotRenounceYet.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertNotEq(_pendingStart(address(this)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can complete first requester, now, by rolling forward half the time
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

        // but only if you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertNotEq(_pendingStart(address(this)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // actually complete it!
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(owner, address(this));
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(_pendingStart(address(this)), 0);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // can't complete it twice
        vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));

        // and to 2nd requester
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), user);
        IBaoOwnable(ownable).completeOwnershipHandover(user);
        assertEq(_pendingStart(user), 0);
        assertEq(IBaoOwnable(ownable).owner(), user);

        // owner's request is still there, so complete it
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(user, owner);
        vm.prank(user); // the current owner
        IBaoOwnable(ownable).completeOwnershipHandover(owner);
        assertEq(_pendingStart(owner), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);
    }

    enum WhatHappened {
        Cancel1stPeriod,
        Cancel2ndPeriod,
        TimePassed,
        Completed
    }

    function _twoStepTransferTiming(WhatHappened what) private {
        // owner is initially set to the owner
        DerivedBaoOwnable(ownable).initialize(owner);

        // cancel - no effect
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverCanceled(user);
        vm.prank(user);
        IBaoOwnable(ownable).cancelOwnershipHandover();

        // transfer two-step to this
        assertEq(_pendingStart(ownable), 0);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(this));
        uint256 thisExpiry = _pendingStart(ownable);
        assertEq(thisExpiry, block.timestamp + DerivedBaoOwnable(ownable).ownershipHandoverValidFor());
        // and to user, after a bit
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 4); // 1/4 of the way through
        vm.prank(ownable);
        IBaoOwnable(ownable).initiateOwnershipHandover(user);
        uint256 userExpiry = _pendingStart(ownable);
        assertEq(userExpiry, block.timestamp + DerivedBaoOwnable(ownable).ownershipHandoverValidFor());
        assertEq(_pendingStart(ownable), thisExpiry);

        if (what == WhatHappened.Cancel1stPeriod) {
            // cancel
            vm.expectEmit();
            emit IBaoOwnable.OwnershipHandoverCanceled(user);
            vm.prank(user);
            IBaoOwnable(ownable).cancelOwnershipHandover();
        }

        // both should be completable now
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2);

        // can complete first requester
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        if (what == WhatHappened.Cancel2ndPeriod) {
            // cancel
            vm.expectEmit();
            emit IBaoOwnable.OwnershipHandoverCanceled(user);
            vm.prank(user);
            IBaoOwnable(ownable).cancelOwnershipHandover();
        }
        if (what == WhatHappened.TimePassed) {
            // timeout
            skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);
        }

        // and not the 2nd requester, because it has expired/ been cancelled
        vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // cancel again!
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverCanceled(user);
        vm.prank(user);
        IBaoOwnable(ownable).cancelOwnershipHandover();
    }

    function test_twoStepTransferTiming() public {
        _twoStepTransferTiming(WhatHappened.TimePassed);
    }

    function test_twoStepTransferCancel1() public {
        _twoStepTransferTiming(WhatHappened.Cancel1stPeriod);
    }

    function test_twoStepTransferCancel2() public {
        _twoStepTransferTiming(WhatHappened.Cancel2ndPeriod);
    }

    function test_twoStepRenounceSimple() public {
        // owner is initially set to the owner
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // only owner can complete
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't renounce unless there's a request
        assertEq(_pendingStart(address(0)), 0);
        vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // only owner can renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(0));
        assertEq(IBaoOwnable(ownable).owner(), owner);
        assertEq(_pendingStart(address(0)), 0);

        // renounce two-step
        assertEq(_pendingStart(address(0)), 0);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverInitiated(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(0));
        uint256 expiry = _pendingStart(address(0));
        assertNotEq(expiry, 0, "non-zero expiry");
        assertEq(IBaoOwnable(ownable).owner(), owner, "requesting doesn't do the transfer");

        // multiple requests are allowed
        skip(1 hours);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverInitiated(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(0));
        assertEq(expiry + 1 hours, _pendingStart(address(0)));

        // can't complete requester yet
        vm.expectRevert(IBaoOwnable.CannotRenounceYet.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(0));
        assertNotEq(_pendingStart(address(0)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can complete, now, by rolling forward half the time
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

        // and only if you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(address(0));
        assertNotEq(_pendingStart(address(0)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // actually complete it!
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(owner, address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(0));
        assertEq(_pendingStart(address(0)), 0);
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function _twoStepRenounce(WhatHappened what) private {
        // owner is initially set to the owner
        DerivedBaoOwnable(ownable).initialize(owner);

        // cancel - no effect
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverCanceled(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).cancelOwnershipHandover();

        // transfer two-step to this
        assertEq(_pendingStart(address(0)), 0);
        vm.prank(owner);
        IBaoOwnable(ownable).initiateOwnershipHandover(address(0));
        uint256 thisExpiry = _pendingStart(address(0));
        assertEq(thisExpiry, block.timestamp + DerivedBaoOwnable(ownable).ownershipHandoverValidFor());

        if (what == WhatHappened.Cancel1stPeriod) {
            vm.expectRevert(IBaoOwnable.Unauthorized.selector);
            IBaoOwnable(ownable).cancelOwnershipHandover();

            // cancel
            vm.expectEmit();
            emit IBaoOwnable.OwnershipHandoverCanceled(address(0));
            vm.prank(owner);
            IBaoOwnable(ownable).cancelOwnershipHandover();

            vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipHandover(address(0));
            assertEq(IBaoOwnable(ownable).owner(), owner);
        }

        // should be completable now
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2);

        if (what == WhatHappened.Cancel2ndPeriod) {
            vm.expectRevert(IBaoOwnable.Unauthorized.selector);
            IBaoOwnable(ownable).cancelOwnershipHandover();

            // cancel
            vm.expectEmit();
            emit IBaoOwnable.OwnershipHandoverCanceled(address(0));
            vm.prank(owner);
            IBaoOwnable(ownable).cancelOwnershipHandover();
        }

        if (what == WhatHappened.Cancel1stPeriod) {
            vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipHandover(address(0));
            assertEq(IBaoOwnable(ownable).owner(), owner);
        } else if (what == WhatHappened.Completed) {
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipHandover(address(0));
            assertEq(IBaoOwnable(ownable).owner(), address(0));
        } else if (what == WhatHappened.TimePassed) {
            // timeout
            skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

            vm.expectRevert(IBaoOwnable.NoHandoverInitiated.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipHandover(address(0));
            assertEq(IBaoOwnable(ownable).owner(), owner);
        }
    }

    function test_twoStepRenounceTiming() public {
        _twoStepRenounce(WhatHappened.TimePassed);
    }

    function test_twoStepRenounceCancel1() public {
        _twoStepRenounce(WhatHappened.Cancel1stPeriod);
    }

    function test_twoStepRenounceCancel2() public {
        _twoStepRenounce(WhatHappened.Cancel2ndPeriod);
    }

    function test_twoStepRenounceCompleted() public {
        _twoStepRenounce(WhatHappened.Completed);
    }
}
