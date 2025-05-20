// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoRoles_v2} from "@bao/internal/BaoRoles_v2.sol";
import {BaoOwnableRoles_v2} from "@bao/BaoOwnableRoles_v2.sol";

import {TestBaoOwnable_v2Only} from "./BaoOwnable_v2.t.sol";
import {TestBaoRoles_v2} from "./BaoRoles_v2.t.sol";

contract DerivedBaoOwnableRoles_v2 is BaoOwnableRoles_v2 {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    constructor(address owner) BaoOwnableRoles_v2(owner) {}

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
}

contract TestBaoOwnableRoles_v2 is TestBaoOwnable_v2Only, TestBaoRoles_v2 {
    address ownable;

    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableRoles_v2(owner));
    }

    function test_introspection() public override {
        TestBaoOwnable_v2Only.test_introspection();
        TestBaoRoles_v2._introspection(ownable);
    }

    function test_roles() public {
        _initialize(owner);

        TestBaoRoles_v2._roles(ownable, owner, user);
    }
}
