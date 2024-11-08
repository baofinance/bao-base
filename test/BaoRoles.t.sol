// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoRoles} from "@bao/internal/BaoRoles.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

import {TestBaoOwnableOnly} from "./BaoOwnable.t.sol";

abstract contract DerivedBaoRoles is BaoRoles {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
    function protectedRolesOrOwner() public view onlyRolesOrOwner(MY_ROLE) {}
}

abstract contract TestBaoRoles is Test {
    function _introspection(address roles) internal view {
        assertTrue(IERC165(roles).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(roles).supportsInterface(type(IBaoRoles).interfaceId));
    }

    function _roles(address roles, address owner, address user) internal {
        // check basic owner & role based protections, to ensure those functions are there
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedRoles();

        uint256 myRole = DerivedBaoRoles(roles).MY_ROLE();
        uint256 anotherRole = DerivedBaoRoles(roles).ANOTHER_ROLE();
        uint256 yetAnotherRole = DerivedBaoRoles(roles).YET_ANOTHER_ROLE();

        // test any and all for 0 roles
        assertEq(IBaoRoles(roles).rolesOf(user), 0);
        assertFalse(IBaoRoles(roles).hasAnyRole(user, myRole));
        assertFalse(IBaoRoles(roles).hasAllRoles(user, myRole));

        // only owner can grant
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(roles).grantRoles(user, myRole);

        // grant 1
        vm.prank(owner);
        IBaoRoles(roles).grantRoles(user, myRole);
        assertEq(IBaoRoles(roles).rolesOf(user), myRole);
        assertTrue(IBaoRoles(roles).hasAnyRole(user, myRole + anotherRole));
        assertTrue(IBaoRoles(roles).hasAnyRole(user, myRole));
        assertFalse(IBaoRoles(roles).hasAnyRole(user, anotherRole));
        assertFalse(IBaoRoles(roles).hasAllRoles(user, anotherRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, myRole));
        assertTrue(IBaoRoles(roles).hasAnyRole(user, 0xFFFF));
        assertFalse(IBaoRoles(roles).hasAllRoles(user, 0xFFFF));

        // do roles prevent?
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedRoles();
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedOwnerOrRoles();
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedRolesOrOwner();

        // do roles allow
        vm.prank(user);
        DerivedBaoRoles(roles).protectedRoles();
        vm.prank(user);
        DerivedBaoRoles(roles).protectedOwnerOrRoles();
        vm.prank(user);
        DerivedBaoRoles(roles).protectedRolesOrOwner();

        // do ownerOr allow
        vm.prank(owner);
        DerivedBaoRoles(roles).protectedOwnerOrRoles();
        vm.prank(owner);
        DerivedBaoRoles(roles).protectedRolesOrOwner();

        // grant 2 new
        vm.prank(owner);
        IBaoRoles(roles).grantRoles(user, anotherRole + yetAnotherRole);
        assertEq(IBaoRoles(roles).rolesOf(user), myRole + anotherRole + yetAnotherRole);
        assertTrue(IBaoRoles(roles).hasAnyRole(user, myRole));
        assertTrue(IBaoRoles(roles).hasAnyRole(user, anotherRole));
        assertTrue(IBaoRoles(roles).hasAnyRole(user, yetAnotherRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, myRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, myRole + anotherRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, anotherRole + yetAnotherRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, myRole + anotherRole + yetAnotherRole));
        assertTrue(IBaoRoles(roles).hasAnyRole(user, 0xFFFF));
        assertFalse(IBaoRoles(roles).hasAllRoles(user, 0xFFFF));

        // and a different user
        vm.prank(owner);
        IBaoRoles(roles).grantRoles(address(this), anotherRole);
        assertEq(IBaoRoles(roles).rolesOf(address(this)), anotherRole);

        // remove
        // not anyone can
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(roles).revokeRoles(user, myRole);
        // owner can
        vm.prank(owner);
        IBaoRoles(roles).revokeRoles(user, myRole);
        assertEq(IBaoRoles(roles).rolesOf(user), anotherRole + yetAnotherRole);
        assertEq(IBaoRoles(roles).rolesOf(address(this)), anotherRole);
        // as can the user
        vm.prank(user);
        IBaoRoles(roles).renounceRoles(anotherRole);
        assertEq(IBaoRoles(roles).rolesOf(user), yetAnotherRole);
        assertEq(IBaoRoles(roles).rolesOf(address(this)), anotherRole);

        //IBaoRoles(roles).grantRoles(user, myRole);
    }
}
