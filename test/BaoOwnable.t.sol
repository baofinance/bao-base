// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";
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

contract TestBaoOwnable is Test {
    address baoOwnable;
    address owner;
    address user;

    function setUp() public virtual {
        owner = vm.createWallet("owner").addr;
        user = vm.createWallet("user").addr;

        baoOwnable = address(new DerivedBaoOwnable());
    }

    function test_init() public {
        // console2.logBytes32(
        //     keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable")) - 1)) & ~bytes32(uint256(0xff))
        // );
        // member data
        assertEq(IOwnable(baoOwnable).owner(), address(0));

        // can't transfer ownership, there's no owner or deployer yet
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(baoOwnable).transferOwnership(owner);

        // can't initialise to 0
        vm.expectRevert(IOwnable.NewOwnerIsZeroAddress.selector);
        DerivedBaoOwnable(baoOwnable).initialize(address(0));

        // can initialise to an owner
        DerivedBaoOwnable(baoOwnable).initialize(owner);
        assertEq(IOwnable(baoOwnable).owner(), owner);

        // can't initialise again
        vm.expectRevert(IOwnable.AlreadyInitialized.selector);
        DerivedBaoOwnable(baoOwnable).initialize(user);
        assertEq(IOwnable(baoOwnable).owner(), owner);

        // introspection
        assertTrue(IERC165(baoOwnable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(baoOwnable).supportsInterface(type(IOwnable).interfaceId));
    }

    function test_deploy() public {
        // initialise to target owner immediately
        DerivedBaoOwnable(baoOwnable).initialize(owner);

        // deployer can't transfer ownership
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(baoOwnable).transferOwnership(user);

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(owner);
        IOwnable(baoOwnable).transferOwnership(user);
        assertEq(IOwnable(baoOwnable).owner(), owner);
    }

    function test_deployWithTransfer() public {
        // owner is initially set to the deployer
        DerivedBaoOwnable(baoOwnable).initialize(address(this));

        // owner can't transfer ownership (one-step)
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(owner);
        IOwnable(baoOwnable).transferOwnership(user);

        // deployer can transfer ownership
        IOwnable(baoOwnable).transferOwnership(owner);
        assertEq(IOwnable(baoOwnable).owner(), owner);

        // deployer can't transfer ownership twice
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(baoOwnable).transferOwnership(user);
        assertEq(IOwnable(baoOwnable).owner(), owner);

        // owner can't use one-step transfer
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(owner);
        IOwnable(baoOwnable).transferOwnership(user);
        assertEq(IOwnable(baoOwnable).owner(), owner);
    }

    function test_oneStepDisabled() public {
        // owner is initially set to the deployer
        DerivedBaoOwnable(baoOwnable).initialize(address(this));
        IOwnable(baoOwnable).transferOwnership(owner);

        // transfer two-step back to deployer
        IOwnable(baoOwnable).requestOwnershipHandover();
        assertEq(IOwnable(baoOwnable).owner(), owner);
        vm.prank(owner);
        IOwnable(baoOwnable).completeOwnershipHandover(address(this));
        assertEq(IOwnable(baoOwnable).owner(), address(this));

        // now the deployer can't one-step transfer
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(baoOwnable).transferOwnership(user);
        assertEq(IOwnable(baoOwnable).owner(), address(this));
    }
}
