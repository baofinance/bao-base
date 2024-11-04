// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IBaoOwnable } from "@bao/interfaces/IBaoOwnable.sol";
import { IBaoOwnableRoles } from "@bao/interfaces/IBaoOwnableRoles.sol";
import { BaoOwnableRoles } from "@bao/BaoOwnableRoles.sol";

import { TestBaoOwnableOnly } from "./BaoOwnable.t.sol";

contract DerivedBaoOwnableRoles is BaoOwnableRoles {
    uint256 public MY_ROLE = _ROLE_1;

    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function ownershipHandoverValidFor() public pure returns (uint64) {
        return 4 days;
    }

    function protected() public view onlyOwner {}

    function protectedRoles() public view onlyRoles(MY_ROLE) {}
}

contract TestBaoOwnableRoles is TestBaoOwnableOnly {
    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableRoles());
    }

    function test_roles() public {
        _initialize(owner);

        // check basic owner & role based protections, to ensure those functions are there
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoOwnableRoles(ownable).protectedRoles();

        uint256 myRole = DerivedBaoOwnableRoles(ownable).MY_ROLE();

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnableRoles(ownable).grantRoles(user, myRole);
        assertFalse(IBaoOwnableRoles(ownable).hasAnyRole(user, myRole));

        vm.prank(owner);
        IBaoOwnableRoles(ownable).grantRoles(user, myRole);
        assertTrue(IBaoOwnableRoles(ownable).hasAnyRole(user, myRole));
        assertTrue(IBaoOwnableRoles(ownable).hasAllRoles(user, myRole));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        DerivedBaoOwnableRoles(ownable).protectedRoles();

        vm.prank(user);
        DerivedBaoOwnableRoles(ownable).protectedRoles();
    }
}
