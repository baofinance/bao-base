// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Ownable } from "@solady/auth/Ownable.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";

contract DerivedOwnable is Ownable {
    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function ownershipHandoverValidFor() public view returns (uint64) {
        return _ownershipHandoverValidFor();
    }

    function protected() public onlyOwner {}
}

contract TestOwnable is Test {
    address ownable;
    address owner;
    address user;

    function setUp() public virtual {
        owner = vm.createWallet("owner").addr;
        user = vm.createWallet("user").addr;

        ownable = address(new DerivedOwnable());
    }

    function test_init() public {
        // member data
        assertEq(IOwnable(ownable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(ownable).transferOwnership(owner);

        // can initialise to 0
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(address(0), address(0));
        DerivedOwnable(ownable).initialize(address(0));
        assertEq(IOwnable(ownable).owner(), address(0));

        // can initialise to an owner, and initialize twice
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(address(0), owner);
        DerivedOwnable(ownable).initialize(owner);
        assertEq(IOwnable(ownable).owner(), owner);

        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(address(0), user);
        DerivedOwnable(ownable).initialize(user);
        assertEq(IOwnable(ownable).owner(), user);
    }

    function test_deployNoTransfer() public {
        // initialise to target owner immediately
        DerivedOwnable(ownable).initialize(owner);

        // deployer can't transfer ownership
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(ownable).transferOwnership(user);

        // owner can transfer ownership (one-step)!
        vm.prank(owner);
        IOwnable(ownable).transferOwnership(user);
        assertEq(IOwnable(ownable).owner(), user);
    }

    function test_deployWithTransfer() public {
        // owner is initially set to the deployer
        DerivedOwnable(ownable).initialize(address(this));

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(owner);
        IOwnable(ownable).transferOwnership(user);

        // deployer can transfer ownership
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(address(this), owner);
        IOwnable(ownable).transferOwnership(owner);
        assertEq(IOwnable(ownable).owner(), owner);

        // deployer can't transfer ownership twice
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(ownable).transferOwnership(user);
        assertEq(IOwnable(ownable).owner(), owner);

        // owner can use one-step transfer!
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(owner, user);
        vm.prank(owner);
        IOwnable(ownable).transferOwnership(user);
        assertEq(IOwnable(ownable).owner(), user);
    }

    function test_oneStepNotDisabled() public {
        // owner is initially set to the deployer
        DerivedOwnable(ownable).initialize(address(this));
        IOwnable(ownable).transferOwnership(owner);

        // transfer two-step back to deployer
        IOwnable(ownable).requestOwnershipHandover();
        assertEq(IOwnable(ownable).owner(), owner);
        vm.prank(owner);
        IOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IOwnable(ownable).owner(), address(this));

        // now the deployer can one-step transfer
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(address(this), user);
        IOwnable(ownable).transferOwnership(user);
        assertEq(IOwnable(ownable).owner(), user);
    }

    function test_twoStepTransfer() public {
        // owner is initially set to the owner
        DerivedOwnable(ownable).initialize(owner);

        // transfer two-step to this
        assertEq(IOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        IOwnable(ownable).requestOwnershipHandover();

        assertEq(IOwnable(ownable).owner(), owner);
        // can't complete to other than requester
        vm.expectRevert(IOwnable.NoHandoverRequest.selector);
        vm.prank(owner);
        IOwnable(ownable).completeOwnershipHandover(user);
        // multiple requests
        vm.prank(user);
        IOwnable(ownable).requestOwnershipHandover();

        // can complete first requester
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(owner, address(this));
        vm.prank(owner);
        IOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IOwnable(ownable).owner(), address(this));

        // and to 2nd requester
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(address(this), user);
        IOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IOwnable(ownable).owner(), user);
    }

    function test_twoStepTransferTiming() public {
        // owner is initially set to the owner
        DerivedOwnable(ownable).initialize(owner);

        // transfer two-step to this
        assertEq(IOwnable(ownable).ownershipHandoverExpiresAt(address(this)), 0);
        IOwnable(ownable).requestOwnershipHandover();
        assertEq(
            IOwnable(ownable).ownershipHandoverExpiresAt(address(this)),
            block.timestamp + DerivedOwnable(ownable).ownershipHandoverValidFor()
        );
        vm.prank(user);
        IOwnable(ownable).requestOwnershipHandover();
        assertEq(
            IOwnable(ownable).ownershipHandoverExpiresAt(user),
            block.timestamp + DerivedOwnable(ownable).ownershipHandoverValidFor()
        );

        skip(DerivedOwnable(ownable).ownershipHandoverValidFor() / 2);

        // can complete first requester
        vm.prank(owner);
        IOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IOwnable(ownable).owner(), address(this));

        skip(DerivedOwnable(ownable).ownershipHandoverValidFor() / 2 + 1);

        // and not the 2nd requester
        vm.expectRevert(IOwnable.NoHandoverRequest.selector);
        IOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IOwnable(ownable).owner(), address(this));
    }

    function test_twoStepTransferCancel() public {
        // owner is initially set to the owner
        DerivedOwnable(ownable).initialize(owner);

        // transfer two-step to this
        IOwnable(ownable).requestOwnershipHandover();
        vm.prank(user);
        IOwnable(ownable).requestOwnershipHandover();

        // can complete first requester
        vm.prank(owner);
        IOwnable(ownable).completeOwnershipHandover(address(this));
        assertEq(IOwnable(ownable).owner(), address(this));

        // and not the 2nd requester
        vm.prank(user);
        IOwnable(ownable).cancelOwnershipHandover();

        vm.expectRevert(IOwnable.NoHandoverRequest.selector);
        IOwnable(ownable).completeOwnershipHandover(user);
        assertEq(IOwnable(ownable).owner(), address(this));
    }

    function test_renounceOwnership() public {
        // owner is initially set to the owner
        DerivedOwnable(ownable).initialize(owner);
        assertEq(IOwnable(ownable).owner(), owner);

        // not owner can't
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(ownable).renounceOwnership();
        assertEq(IOwnable(ownable).owner(), owner);

        // owner can
        vm.expectEmit();
        emit IOwnable.OwnershipTransferred(owner, address(0));
        vm.prank(owner);
        IOwnable(ownable).renounceOwnership();
        assertEq(IOwnable(ownable).owner(), address(0));

        // and has
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(owner);
        IOwnable(ownable).renounceOwnership();
    }
}
