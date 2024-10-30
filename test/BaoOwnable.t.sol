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

    function test_init() public {
        // member data
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);

        // can't initialise to 0, if you want that use renounceOwnership
        vm.expectRevert(IBaoOwnable.NewOwnerIsZeroAddress.selector);
        DerivedBaoOwnable(ownable).initialize(address(0));

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
        vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(user);

        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
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
        IBaoOwnable(ownable).renounceOwnership();
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't initialise again after a transfer
        vm.expectRevert(IBaoOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function test_transfer1step() public {
        DerivedBaoOwnable(ownable).initialize(address(this));
        vm.expectRevert(IBaoOwnable.NewOwnerIsZeroAddress.selector);
        IBaoOwnable(ownable).transferOwnership(address(0));
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
        IBaoOwnable(ownable).renounceOwnership();
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

    function test_deployWithRenounce() public {
        // owner is initially set to the deployer
        DerivedBaoOwnable(ownable).initialize(address(this));

        // owner can't renounce ownership (one-step)
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).renounceOwnership();

        // deployer can renounce ownership
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), address(0));
        IBaoOwnable(ownable).renounceOwnership();
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // deployer can't transfer ownership twice
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).renounceOwnership();
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
        IBaoOwnable(ownable).renounceOwnership();
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // owner can't transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(address(this));
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // transfer two-step back to deployer to see if there are any residuals
        IBaoOwnable(ownable).requestOwnershipHandover();
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
        IBaoOwnable(ownable).renounceOwnership();
        assertEq(IBaoOwnable(ownable).owner(), address(this));
    }

    function test_oneStepDisabledRenounce() public {
        DerivedBaoOwnable(ownable).initialize(address(this));
        assertEq(IBaoOwnable(ownable).owner(), address(this));
        IBaoOwnable(ownable).renounceOwnership();
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).renounceOwnership();
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        //  can't transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).transferOwnership(owner);
        assertEq(IBaoOwnable(ownable).owner(), address(0));

        // can't even request a transfer
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).requestOwnershipHandover();

        // can't even request a transfer or a renunciation
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).requestOwnershipRenunciation();
    }

    function test_twoStepTransferSimple() public {
        // owner is initially set to the owner
        DerivedBaoOwnable(ownable).initialize(owner);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't handover unless you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(user);

        // even for the owner, there must be a request
        vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can request to yourself
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverRequested(owner);
        vm.prank(owner);
        IBaoOwnable(ownable).requestOwnershipHandover();

        // transfer two-step to this
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverRequested(address(this));
        IBaoOwnable(ownable).requestOwnershipHandover();
        uint256 expiry = IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this));
        assertNotEq(expiry, 0, "non-zero expiry");
        assertEq(IBaoOwnable(ownable).owner(), owner, "requesting doesn't do the transfer");

        // multiple requests are allowed
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverRequested(user);
        vm.prank(user);
        IBaoOwnable(ownable).requestOwnershipHandover();
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), expiry, "both 1 non-zero expiry");
        assertNotEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(user), 0, "both 2 non-zero expiry");

        // multiple requests are allowed to the same address, just delays it
        skip(1 hours);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverRequested(address(this));
        IBaoOwnable(ownable).requestOwnershipHandover();
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), expiry + 1 hours);

        // can't complete first requester yet
        vm.expectRevert(IBaoOwnable.CannotCompleteYet.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertNotEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can complete first requester, now, by rolling forward half the time
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

        // but only if you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertNotEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // actually complete it!
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(owner, address(this));
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        assertEq(IBaoOwnable(ownable).owner(), address(this));

        // can't complete it twice
        vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
        IBaoOwnable(ownable).completeOwnershipHandover(address(this));

        // and to 2nd requester
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(this), user);
        IBaoOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(user), 0);
        assertEq(IBaoOwnable(ownable).owner(), user);

        // owner's request is still there, so complete it
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(user, owner);
        vm.prank(user); // the current owner
        IBaoOwnable(ownable).completeOwnershipHandover(owner);
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(owner), 0);
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
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        IBaoOwnable(ownable).requestOwnershipHandover();
        uint256 thisExpiry = IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this));
        assertEq(thisExpiry, block.timestamp + DerivedBaoOwnable(ownable).ownershipHandoverValidFor());
        // and to user, after a bit
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 4); // 1/4 of the way through
        vm.prank(user);
        IBaoOwnable(ownable).requestOwnershipHandover();
        uint256 userExpiry = IBaoOwnable(ownable).ownershipHandoverExpiresAt(user);
        assertEq(userExpiry, block.timestamp + DerivedBaoOwnable(ownable).ownershipHandoverValidFor());
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(this)), thisExpiry);

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
        vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
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
        IBaoOwnable(ownable).completeOwnershipRenunciation();
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can't renounce unless there's a request
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);
        vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipRenunciation();
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // only owner can renounce
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).requestOwnershipRenunciation();
        assertEq(IBaoOwnable(ownable).owner(), owner);
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);

        // renounce two-step
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverRequested(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).requestOwnershipRenunciation();
        uint256 expiry = IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0));
        assertNotEq(expiry, 0, "non-zero expiry");
        assertEq(IBaoOwnable(ownable).owner(), owner, "requesting doesn't do the transfer");

        // multiple requests are allowed
        skip(1 hours);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverRequested(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).requestOwnershipRenunciation();
        assertEq(expiry + 1 hours, IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)));

        // can't complete requester yet
        vm.expectRevert(IBaoOwnable.CannotCompleteYet.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipRenunciation();
        assertNotEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // can complete, now, by rolling forward half the time
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

        // but not by using the completeOwnershipHandover call - must use the renunciation
        vm.expectRevert(IBaoOwnable.NewOwnerIsZeroAddress.selector);
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipHandover(address(0));

        // and only if you're the owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(ownable).completeOwnershipRenunciation();
        assertNotEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);
        assertEq(IBaoOwnable(ownable).owner(), owner);

        // actually complete it!
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(owner, address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).completeOwnershipRenunciation();
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);
        assertEq(IBaoOwnable(ownable).owner(), address(0));
    }

    function _twoStepRenounce(WhatHappened what) private {
        // owner is initially set to the owner
        DerivedBaoOwnable(ownable).initialize(owner);

        // cancel - no effect
        vm.expectEmit();
        emit IBaoOwnable.OwnershipHandoverCanceled(address(0));
        vm.prank(owner);
        IBaoOwnable(ownable).cancelOwnershipRenunciation();

        // transfer two-step to this
        assertEq(IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0)), 0);
        vm.prank(owner);
        IBaoOwnable(ownable).requestOwnershipRenunciation();
        uint256 thisExpiry = IBaoOwnable(ownable).ownershipHandoverExpiresAt(address(0));
        assertEq(thisExpiry, block.timestamp + DerivedBaoOwnable(ownable).ownershipHandoverValidFor());

        if (what == WhatHappened.Cancel1stPeriod) {
            vm.expectRevert(IBaoOwnable.Unauthorized.selector);
            IBaoOwnable(ownable).cancelOwnershipRenunciation();

            // cancel
            vm.expectEmit();
            emit IBaoOwnable.OwnershipHandoverCanceled(address(0));
            vm.prank(owner);
            IBaoOwnable(ownable).cancelOwnershipRenunciation();

            vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipRenunciation();
            assertEq(IBaoOwnable(ownable).owner(), owner);
        }

        // should be completable now
        skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2);

        if (what == WhatHappened.Cancel2ndPeriod) {
            vm.expectRevert(IBaoOwnable.Unauthorized.selector);
            IBaoOwnable(ownable).cancelOwnershipRenunciation();

            // cancel
            vm.expectEmit();
            emit IBaoOwnable.OwnershipHandoverCanceled(address(0));
            vm.prank(owner);
            IBaoOwnable(ownable).cancelOwnershipRenunciation();
        }

        if (what == WhatHappened.Cancel1stPeriod) {
            vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipRenunciation();
            assertEq(IBaoOwnable(ownable).owner(), owner);
        } else if (what == WhatHappened.Completed) {
            // not be handover
            vm.expectRevert(IBaoOwnable.NewOwnerIsZeroAddress.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipHandover(address(0));

            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipRenunciation();
            assertEq(IBaoOwnable(ownable).owner(), address(0));
        } else if (what == WhatHappened.TimePassed) {
            // timeout
            skip(DerivedBaoOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

            vm.expectRevert(IBaoOwnable.NoHandoverRequest.selector);
            vm.prank(owner);
            IBaoOwnable(ownable).completeOwnershipRenunciation();
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
