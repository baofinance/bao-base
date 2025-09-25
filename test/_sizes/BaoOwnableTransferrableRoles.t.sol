// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoOwnableTransferrableRoles} from "@bao/BaoOwnableTransferrableRoles.sol";

import {TestBaoOwnableTransferrableOnly} from "./BaoOwnableTransferrable.t.sol";
import {TestBaoRoles} from "./BaoRoles.t.sol";

contract DerivedBaoOwnableTransferrableRoles is BaoOwnableTransferrableRoles, TestBaoRoles {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
    function protectedRolesOrOwner() public view onlyRolesOrOwner(MY_ROLE) {}
}

contract TestBaoOwnableTransferrableRoles is TestBaoOwnableTransferrableOnly, TestBaoRoles {
    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableTransferrableRoles());
    }

    function test_introspection() public view override {
        TestBaoOwnableTransferrableOnly.test_introspection();
        TestBaoRoles._introspection(ownable);
    }

    function test_roles() public {
        _initialize(owner);

        // check basic owner & role based protections, to ensure those functions are there
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoOwnableTransferrableRoles(ownable).protectedRoles();

        uint256 myRole = DerivedBaoOwnableTransferrableRoles(ownable).MY_ROLE();

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(ownable).grantRoles(user, myRole);
        assertFalse(IBaoRoles(ownable).hasAnyRole(user, myRole));

        vm.prank(owner);
        IBaoRoles(ownable).grantRoles(user, myRole);
        assertTrue(IBaoRoles(ownable).hasAnyRole(user, myRole));
        assertTrue(IBaoRoles(ownable).hasAllRoles(user, myRole));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoOwnableTransferrableRoles(ownable).protectedRoles();

        vm.prank(user);
        DerivedBaoOwnableTransferrableRoles(ownable).protectedRoles();
    }
}
