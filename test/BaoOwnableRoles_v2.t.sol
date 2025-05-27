// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoRoles_v2} from "@bao/internal/BaoRoles_v2.sol";
import {BaoOwnableRoles_v2} from "@bao/BaoOwnableRoles_v2.sol";
import {IBaoOwnable_v2} from "@bao/interfaces/IBaoOwnable_v2.sol";

import {TestBaoOwnable_v2Only} from "./BaoOwnable_v2.t.sol";
import {TestBaoRoles_v2} from "./BaoRoles_v2.t.sol";

contract DerivedBaoOwnableRoles_v2 is BaoOwnableRoles_v2 {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    constructor(address owner, uint256 delay) BaoOwnableRoles_v2(owner, delay) {}

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
}

contract TestBaoOwnableRoles_v2 is TestBaoOwnable_v2Only, TestBaoRoles_v2 {
    function setUp() public override {
        super.setUp();
    }

    function test_introspection() public override {
        address ownable = _initializeRoles(owner, 3600);
        TestBaoOwnable_v2Only._introspectionOnly(ownable);
        TestBaoRoles_v2._introspection(ownable);
    }

    function _initializeRoles(address owner_, uint256 delay) internal returns (address ownable) {
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnable_v2.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnable_v2.OwnershipTransferred(address(this), owner_);
        ownable = address(new DerivedBaoOwnableRoles_v2(owner_, delay));

        if (delay > 0) {
            assertEq(IBaoOwnable_v2(ownable).owner(), address(this));

            // move timestamop forward just short of the hour
            // console2.log("block.timestamp", block.timestamp);
            skip(delay - 1);
            // console2.log("block.timestamp", block.timestamp);
            assertEq(IBaoOwnable_v2(ownable).owner(), address(this));
            // now we trigger the transfer
            skip(1);
        }
        // console2.log("block.timestamp", block.timestamp);
        assertEq(IBaoOwnable_v2(ownable).owner(), owner_);
    }

    function test_roles(uint256 delay) public {
        delay = bound(delay, 0, 1 hours);
        address ownable = _initializeRoles(owner, delay);

        TestBaoRoles_v2._roles(ownable, owner, user);
    }
}
