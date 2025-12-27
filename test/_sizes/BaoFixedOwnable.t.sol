// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";

import {IBaoOwnableFixed} from "@bao/interfaces/IBaoOwnableFixed.sol";
import {BaoFixedOwnable} from "@bao/BaoFixedOwnable.sol";

contract DerivedBaoFixedOwnable is BaoFixedOwnable {
    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) BaoFixedOwnable(beforeOwner, delayedOwner, delay) {}

    function protected() public onlyOwner {}

    function unprotected() public {}
}

contract BaoFixedOwnableDeployer {
    function deploy(address beforeOwner, address delayedOwner, uint256 delay) external returns (address ownable) {
        ownable = address(new DerivedBaoFixedOwnable(beforeOwner, delayedOwner, delay));
    }
}

contract TestBaoFixedOwnableOnly is Test {
    address owner;
    address user;

    function setUp() public virtual {
        owner = makeAddr("owner");
        user = makeAddr("user");
    }

    function _initialize(address beforeOwner, address delayedOwner, uint256 delay) internal returns (address ownable) {
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableFixed.OwnershipTransferred(address(0), beforeOwner);
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableFixed.OwnershipTransferred(beforeOwner, delayedOwner);
        ownable = address(new DerivedBaoFixedOwnable(beforeOwner, delayedOwner, delay));

        if (delay > 0) {
            assertEq(IBaoOwnableFixed(ownable).owner(), beforeOwner);

            skip(delay - 1);
            assertEq(IBaoOwnableFixed(ownable).owner(), beforeOwner);

            skip(1);
        }

        assertEq(IBaoOwnableFixed(ownable).owner(), delayedOwner);
    }

    function _introspectionOnly(address ownable) internal view {
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IBaoOwnableFixed).interfaceId));
    }

    function test_introspection() public virtual {
        address ownable = address(new DerivedBaoFixedOwnable(address(0), address(0), 0));
        _introspectionOnly(ownable);
    }

    function test_onlyOwner() public {
        address ownable = address(new DerivedBaoFixedOwnable(address(this), owner, 3600));

        DerivedBaoFixedOwnable(ownable).protected();
        DerivedBaoFixedOwnable(ownable).unprotected();

        vm.prank(owner);
        DerivedBaoFixedOwnable(ownable).unprotected();

        vm.prank(owner);
        vm.expectRevert(IBaoOwnableFixed.Unauthorized.selector);
        DerivedBaoFixedOwnable(ownable).protected();

        skip(3600);

        DerivedBaoFixedOwnable(ownable).unprotected();

        vm.expectRevert(IBaoOwnableFixed.Unauthorized.selector);
        DerivedBaoFixedOwnable(ownable).protected();

        vm.prank(owner);
        DerivedBaoFixedOwnable(ownable).unprotected();

        vm.prank(owner);
        DerivedBaoFixedOwnable(ownable).protected();
    }

    function test_onlyOwner0() public {
        address ownable = address(new DerivedBaoFixedOwnable(address(this), address(0), 3600));

        DerivedBaoFixedOwnable(ownable).protected();
        assertEq(IBaoOwnableFixed(ownable).owner(), address(this));

        skip(3600);

        vm.expectRevert(IBaoOwnableFixed.Unauthorized.selector);
        DerivedBaoFixedOwnable(ownable).protected();
        assertEq(IBaoOwnableFixed(ownable).owner(), address(0));
    }

    function test_transfer1stepZero(uint256 delay) public {
        delay = bound(delay, 0, 1 weeks);
        _initialize(address(this), address(0), delay);
    }

    function test_transfer1stepThis(uint256 delay) public {
        delay = bound(delay, 0, 1 weeks);
        _initialize(address(this), address(this), delay);
    }

    function test_transfer1stepAnother(uint256 delay) public {
        delay = bound(delay, 0, 1 weeks);
        _initialize(address(this), user, delay);
    }

    function test_beforeOwnerIsExplicitNotDeployer(uint256 delay) public {
        delay = bound(delay, 1, 1 weeks);

        address beforeOwner = makeAddr("beforeOwner");
        BaoFixedOwnableDeployer deployer = new BaoFixedOwnableDeployer();

        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableFixed.OwnershipTransferred(address(0), beforeOwner);
        vm.expectEmit(true, true, true, true);
        emit IBaoOwnableFixed.OwnershipTransferred(beforeOwner, owner);
        address ownable = deployer.deploy(beforeOwner, owner, delay);

        assertEq(IBaoOwnableFixed(ownable).owner(), beforeOwner);

        vm.expectRevert(IBaoOwnableFixed.Unauthorized.selector);
        DerivedBaoFixedOwnable(ownable).protected();

        vm.prank(beforeOwner);
        DerivedBaoFixedOwnable(ownable).protected();

        skip(delay);
        assertEq(IBaoOwnableFixed(ownable).owner(), owner);

        vm.expectRevert(IBaoOwnableFixed.Unauthorized.selector);
        vm.prank(beforeOwner);
        DerivedBaoFixedOwnable(ownable).protected();

        vm.prank(owner);
        DerivedBaoFixedOwnable(ownable).protected();
    }
}
