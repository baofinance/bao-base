// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";
import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { BaoOwnableRoles } from "@bao/BaoOwnableRoles.sol";

import { TestBaoOwnableOnly } from "./BaoOwnable.t.sol";

contract DerivedBaoOwnableRoles is BaoOwnableRoles {
    uint256 public MY_ROLE = _ROLE_1;

    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function ownershipHandoverValidFor() public view returns (uint64) {
        return _ownershipHandoverValidFor();
    }

    function protected() public view onlyRoles(MY_ROLE) {}
}

contract TestBaoOwnableRoles is TestBaoOwnableOnly {
    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableRoles());
    }

    function test_roles() public {
        DerivedBaoOwnableRoles(ownable).initialize(owner);

        // check basic owner & role based protections, to ensure thos functions are there
        vm.expectRevert(IOwnable.Unauthorized.selector);
        DerivedBaoOwnableRoles(ownable).protected();

        uint256 myRole = DerivedBaoOwnableRoles(ownable).MY_ROLE();

        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnableRoles(ownable).grantRoles(user, myRole);
        assertFalse(IOwnableRoles(ownable).hasAnyRole(user, myRole));

        vm.prank(owner);
        IOwnableRoles(ownable).grantRoles(user, myRole);
        assertTrue(IOwnableRoles(ownable).hasAnyRole(user, myRole));
        assertTrue(IOwnableRoles(ownable).hasAllRoles(user, myRole));

        vm.expectRevert(IOwnable.Unauthorized.selector);
        DerivedBaoOwnableRoles(ownable).protected();

        vm.prank(user);
        DerivedBaoOwnableRoles(ownable).protected();
    }
}
