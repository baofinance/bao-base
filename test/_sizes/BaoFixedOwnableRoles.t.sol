// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFixedOwnableRoles} from "@bao/BaoFixedOwnableRoles.sol";
import {IBaoFixedOwnable} from "@bao/interfaces/IBaoFixedOwnable.sol";

import {TestBaoFixedOwnableOnly} from "./BaoFixedOwnable.t.sol";
import {TestBaoRoles_v2} from "./BaoRoles_v2.t.sol";

contract DerivedBaoFixedOwnableRoles is BaoFixedOwnableRoles {
    uint256 public MY_ROLE = _ROLE_1;
    uint256 public ANOTHER_ROLE = _ROLE_2;
    uint256 public YET_ANOTHER_ROLE = _ROLE_3;

    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) BaoFixedOwnableRoles(beforeOwner, delayedOwner, delay) {}

    function protected() public view onlyOwner {}
    function protectedRoles() public view onlyRoles(MY_ROLE) {}
    function protectedOwnerOrRoles() public view onlyOwnerOrRoles(MY_ROLE) {}
}

contract TestBaoFixedOwnableRoles is TestBaoFixedOwnableOnly, TestBaoRoles_v2 {
    function setUp() public override {
        super.setUp();
    }

    function test_introspection() public override {
        address ownable = _initializeRoles(owner, 3600);
        TestBaoFixedOwnableOnly._introspectionOnly(ownable);
        TestBaoRoles_v2._introspection(ownable);
    }

    function _initializeRoles(address delayedOwner, uint256 delay) internal returns (address ownable) {
        vm.expectEmit(true, true, true, true);
        emit IBaoFixedOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, true, true);
        emit IBaoFixedOwnable.OwnershipTransferred(address(this), delayedOwner);

        ownable = address(new DerivedBaoFixedOwnableRoles(address(this), delayedOwner, delay));

        if (delay > 0) {
            assertEq(IBaoFixedOwnable(ownable).owner(), address(this));

            skip(delay - 1);
            assertEq(IBaoFixedOwnable(ownable).owner(), address(this));

            skip(1);
        }

        assertEq(IBaoFixedOwnable(ownable).owner(), delayedOwner);
    }

    function test_roles(uint256 delay) public {
        delay = bound(delay, 0, 1 hours);
        address ownable = _initializeRoles(owner, delay);

        TestBaoRoles_v2._roles(ownable, owner, user);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    FACTORY INTEGRATION TESTS (BaoFixedOwnableRoles)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test factory deployment with roles - owner is explicit, not factory
    function test_factoryDeploymentWithRoles() public {
        address intendedOwner = makeAddr("intendedOwner");
        address futureOwner = makeAddr("futureOwner");
        uint256 delay = 1 hours;

        // Simulate factory deployment by deploying from a different contract
        vm.prank(makeAddr("factory"));
        DerivedBaoFixedOwnableRoles ownable = new DerivedBaoFixedOwnableRoles(intendedOwner, futureOwner, delay);

        // Owner is explicit parameter, not factory
        assertEq(IBaoFixedOwnable(address(ownable)).owner(), intendedOwner);

        // Cache role before prank (prank only affects next call)
        uint256 myRole = ownable.MY_ROLE();

        // Owner can grant roles
        vm.prank(intendedOwner);
        ownable.grantRoles(user, myRole);

        // User with role can access role-protected function
        vm.prank(user);
        ownable.protectedRoles();

        // After delay, new owner can manage roles
        skip(delay);
        assertEq(IBaoFixedOwnable(address(ownable)).owner(), futureOwner);

        vm.prank(futureOwner);
        ownable.revokeRoles(user, myRole);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              EDGE CASE TESTS (Roles)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test very large delay with roles
    function test_veryLargeDelayWithRoles() public {
        uint256 oneYear = 365 days;

        vm.expectEmit(true, true, true, true);
        emit IBaoFixedOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, true, true);
        emit IBaoFixedOwnable.OwnershipTransferred(address(this), owner);

        DerivedBaoFixedOwnableRoles ownable = new DerivedBaoFixedOwnableRoles(address(this), owner, oneYear);

        // Cache role to avoid consuming prank
        uint256 myRole = ownable.MY_ROLE();

        // Grant roles during the year
        ownable.grantRoles(user, myRole);

        vm.prank(user);
        ownable.protectedRoles();

        // After 1 year, new owner can manage roles
        skip(oneYear);
        assertEq(IBaoFixedOwnable(address(ownable)).owner(), owner);

        vm.prank(owner);
        ownable.revokeRoles(user, myRole);

        vm.prank(user);
        vm.expectRevert();
        ownable.protectedRoles();
    }
}
