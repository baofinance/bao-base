// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IBaoOwnableTransferrable } from "@bao/interfaces/IBaoOwnableTransferrable.sol";
import { IBaoRoles } from "@bao/interfaces/IBaoRoles.sol";
import { BaoOwnableTransferrableRoles } from "@bao/BaoOwnableTransferrableRoles.sol";

import { TestBaoOwnableTransferrableOnly } from "./BaoOwnableTransferrable.t.sol";

contract DerivedBaoOwnableTransferrableRoles is BaoOwnableTransferrableRoles {
    uint256 public MY_ROLE = _ROLE_1;

    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function protected() public view onlyOwner {}

    function protectedRoles() public view onlyRoles(MY_ROLE) {}
}

contract TestBaoOwnableTransferrableRoles is TestBaoOwnableTransferrableOnly {
    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableTransferrableRoles());
    }

    function test_roles() public {
        _initialize(owner);

        // check basic owner & role based protections, to ensure those functions are there
        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        DerivedBaoOwnableTransferrableRoles(ownable).protectedRoles();

        uint256 myRole = DerivedBaoOwnableTransferrableRoles(ownable).MY_ROLE();

        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        IBaoRoles(ownable).grantRoles(user, myRole);
        assertFalse(IBaoRoles(ownable).hasAnyRole(user, myRole));

        vm.prank(owner);
        IBaoRoles(ownable).grantRoles(user, myRole);
        assertTrue(IBaoRoles(ownable).hasAnyRole(user, myRole));
        assertTrue(IBaoRoles(ownable).hasAllRoles(user, myRole));

        vm.expectRevert(IBaoOwnableTransferrable.Unauthorized.selector);
        DerivedBaoOwnableTransferrableRoles(ownable).protectedRoles();

        vm.prank(user);
        DerivedBaoOwnableTransferrableRoles(ownable).protectedRoles();
    }
}
