// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFixedOwnableRoles} from "@bao/BaoFixedOwnableRoles.sol";
import {IBaoOwnableFixed} from "@bao/interfaces/IBaoOwnableFixed.sol";

import {TestBaoFixedOwnableOnly} from "./BaoFixedOwnable.t.sol";
import {TestBaoRoles_v2} from "./BaoRoles_v2.t.sol";

contract DerivedBaoFixedOwnableRoles is BaoFixedOwnableRoles {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) BaoFixedOwnableRoles(beforeOwner, delayedOwner, delay) {}

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
}

contract TestBaoFixedOwnableRoles is TestBaoFixedOwnableOnly, TestBaoRoles_v2 {
    function setUp() public override {
        super.setUp();
    }

    function test_introspection() public override {
        address ownable = _initializeRoles(owner, 3600);
        TestBaoFixedOwnableOnly._introspectionOnly(ownable);
        TestBaoRoles_v2._introspection(ownable);
    }

    function _initializeRoles(address delayedOwner, uint256 delay) internal returns (address ownable) {
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableFixed.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableFixed.OwnershipTransferred(address(this), delayedOwner);

        ownable = address(new DerivedBaoFixedOwnableRoles(address(this), delayedOwner, delay));

        if (delay > 0) {
            assertEq(IBaoOwnableFixed(ownable).owner(), address(this));

            skip(delay - 1);
            assertEq(IBaoOwnableFixed(ownable).owner(), address(this));

            skip(1);
        }

        assertEq(IBaoOwnableFixed(ownable).owner(), delayedOwner);
    }

    function test_roles(uint256 delay) public {
        delay = bound(delay, 0, 1 hours);
        address ownable = _initializeRoles(owner, delay);

        TestBaoRoles_v2._roles(ownable, owner, user);
    }
}
