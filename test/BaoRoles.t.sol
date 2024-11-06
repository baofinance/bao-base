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

abstract contract DerivedBaoRoles is BaoRoles {
    uint256 public MY_ROLE = _ROLE_1;
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
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

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(roles).grantRoles(user, myRole);
        assertFalse(IBaoRoles(roles).hasAnyRole(user, myRole));

        vm.prank(owner);
        IBaoRoles(roles).grantRoles(user, myRole);
        assertTrue(IBaoRoles(roles).hasAnyRole(user, myRole));
        assertTrue(IBaoRoles(roles).hasAllRoles(user, myRole));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoRoles(roles).protectedRoles();

        vm.prank(user);
        DerivedBaoRoles(roles).protectedRoles();
    }
}
