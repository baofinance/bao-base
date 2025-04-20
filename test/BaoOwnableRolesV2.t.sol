// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoRolesV2} from "@bao/internal/BaoRolesV2.sol";
import {BaoOwnableRolesV2} from "@bao/BaoOwnableRolesV2.sol";

import {TestBaoOwnableV2Only} from "./BaoOwnableV2.t.sol";
import {TestBaoRolesV2} from "./BaoRolesV2.t.sol";

contract DerivedBaoOwnableRolesV2 is BaoOwnableRolesV2 {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    constructor(address owner) BaoOwnableRolesV2(owner) {}

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
}

contract TestBaoOwnableRolesV2 is TestBaoOwnableV2Only, TestBaoRolesV2 {
    address ownable;

    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableRolesV2(owner));
    }

    function test_introspection() public override {
        TestBaoOwnableV2Only.test_introspection();
        TestBaoRolesV2._introspection(ownable);
    }

    function test_roles() public {
        _initialize(owner);

        TestBaoRolesV2._roles(ownable, owner, user);
    }
}
