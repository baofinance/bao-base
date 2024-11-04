// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";
import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { BaoOwnableRoles } from "@bao/BaoOwnableRoles.sol";

import { TestBaoOwnable } from "./BaoOwnable.t.sol";

contract DerivedBaoOwnableRoles is BaoOwnableRoles {
    uint256 public MY_ROLE = _ROLE_1;

    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function ownershipHandoverValidFor() public pure returns (uint64) {
        return 4 days;
    }

    function protectedO() public onlyOwner {}

    function protected() public view onlyRoles(MY_ROLE) {}
}

contract TestBaoOwnableRoles is TestBaoOwnable {
    function setUp() public override {
        super.setUp();

        baoOwnable = address(new DerivedBaoOwnableRoles());
    }

    function test_roles() public {
        DerivedBaoOwnableRoles(baoOwnable).initialize(owner);

        // check basic owner & role based protections, to ensure thos functions are there
        vm.expectRevert(IOwnable.Unauthorized.selector);
        DerivedBaoOwnableRoles(baoOwnable).protected();

        uint256 myRole = DerivedBaoOwnableRoles(baoOwnable).MY_ROLE();

        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnableRoles(baoOwnable).grantRoles(user, myRole);
        assertFalse(IOwnableRoles(baoOwnable).hasAnyRole(user, myRole));

        vm.prank(owner);
        IOwnableRoles(baoOwnable).grantRoles(user, myRole);
        assertTrue(IOwnableRoles(baoOwnable).hasAnyRole(user, myRole));
        assertTrue(IOwnableRoles(baoOwnable).hasAllRoles(user, myRole));

        vm.expectRevert(IOwnable.Unauthorized.selector);
        DerivedBaoOwnableRoles(baoOwnable).protected();

        vm.prank(user);
        DerivedBaoOwnableRoles(baoOwnable).protected();
    }
}
