// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";
import { IBaoRoles } from "@bao/interfaces/IBaoRoles.sol";
import { BaoRoles } from "@bao/internal/BaoRoles.sol";
import { BaoOwnable } from "@bao/BaoOwnable.sol";

import { TestBaoOwnableOnly } from "./BaoOwnable.t.sol";

contract DerivedBaoRoles is BaoRoles {
    uint256 public MY_ROLE = _ROLE_1;
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
}

contract TestBaoRoles is Test {
    address roles;
    address user;

    function setUp() public {
        roles = address(new DerivedBaoRoles());
        user = vm.createWallet("user").addr;
    }

    function test_roles() public {
        // check basic owner & role based protections, to ensure those functions are there
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedRoles();

        uint256 myRole = DerivedBaoRoles(roles).MY_ROLE();

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(roles).grantRoles(user, myRole);
        assertFalse(IBaoRoles(roles).hasAnyRole(user, myRole));

        /* TODO: should BaoRoles be unprotected in their native form?
        vm.prank(owner);
        IBaoRoles(roles).grantRoles(user, myRole);
        assertTrue(IBaoRoles(roles).hasAnyRole(user, myRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, myRole));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedRoles();

        vm.prank(user);
        DerivedBaoRoles(roles).protectedRoles();
        */
    }
}
