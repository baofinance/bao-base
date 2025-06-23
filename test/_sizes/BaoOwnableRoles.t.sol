// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoRoles} from "@bao/internal/BaoRoles.sol";
import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

import {TestBaoOwnableOnly} from "./BaoOwnable.t.sol";
import {TestBaoRoles} from "./BaoRoles.t.sol";

contract DerivedBaoOwnableRoles is BaoOwnableRoles {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    function initialize(address owner) public {
        _initializeOwner(owner);
    }

    function pendingOwner() public view returns (address pendingOwner_) {
        assembly ("memory-safe") {
            pendingOwner_ := sload(_PENDING_SLOT)
        }
    }

    function pendingExpiry() public view returns (uint64 expiry) {
        assembly ("memory-safe") {
            expiry := shr(192, sload(_PENDING_SLOT))
        }
    }

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
    function protectedRolesOrOwner() public view onlyRolesOrOwner(MY_ROLE) {}
}

contract TestBaoOwnableRoles is TestBaoOwnableOnly, TestBaoRoles {
    function setUp() public override {
        super.setUp();

        ownable = address(new DerivedBaoOwnableRoles());
    }

    function test_introspection() public view override {
        TestBaoOwnableOnly.test_introspection();
        TestBaoRoles._introspection(ownable);
    }

    function test_roles() public {
        _initialize(owner);

        TestBaoRoles._roles(ownable, owner, user);
    }
}
