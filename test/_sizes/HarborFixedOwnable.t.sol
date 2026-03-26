// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {IHarborFixedOwnable} from "@bao/interfaces/IHarborFixedOwnable.sol";
import {HarborFixedOwnable} from "@bao/HarborFixedOwnable.sol";

contract DerivedHarborFixedOwnable is HarborFixedOwnable {
    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) HarborFixedOwnable(beforeOwner, delayedOwner, delay) {}

    function protected() public onlyOwner {}

    function unprotected() public {}
}

contract TestHarborFixedOwnableOnly is BaoTest {
    IBaoFactory public factory;
    address owner;
    address user;

    function setUp() public virtual {
        factory = IBaoFactory(_ensureBaoFactory());
        owner = makeAddr("owner");
        user = makeAddr("user");
    }

    /// @notice Deploy DerivedHarborFixedOwnable via BaoFactory at deterministic address
    function _deployViaFactory(
        bytes32 salt,
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) internal returns (address ownable) {
        bytes memory creationCode = abi.encodePacked(
            type(DerivedHarborFixedOwnable).creationCode,
            abi.encode(beforeOwner, delayedOwner, delay)
        );
        ownable = factory.deploy(creationCode, salt);
    }

    function _initialize(address beforeOwner, address delayedOwner, uint256 delay) internal returns (address ownable) {
        vm.expectEmit(true, true, true, true);
        emit IHarborFixedOwnable.OwnershipTransferred(address(0), beforeOwner);
        vm.expectEmit(true, true, true, true);
        emit IHarborFixedOwnable.OwnershipTransferred(beforeOwner, delayedOwner);
        ownable = address(new DerivedHarborFixedOwnable(beforeOwner, delayedOwner, delay));

        if (delay > 0) {
            assertEq(IHarborFixedOwnable(ownable).owner(), beforeOwner);

            skip(delay - 1);
            assertEq(IHarborFixedOwnable(ownable).owner(), beforeOwner);

            skip(1);
        }

        assertEq(IHarborFixedOwnable(ownable).owner(), delayedOwner);
    }

    function _introspectionOnly(address ownable) internal view {
        assertTrue(IERC165(ownable).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(ownable).supportsInterface(type(IHarborFixedOwnable).interfaceId));
    }

    function test_introspection() public virtual {
        address ownable = address(new DerivedHarborFixedOwnable(address(this), owner, 0));
        _introspectionOnly(ownable);
    }

    function test_onlyOwner() public {
        address ownable = address(new DerivedHarborFixedOwnable(address(this), owner, 3600));

        DerivedHarborFixedOwnable(ownable).protected();
        DerivedHarborFixedOwnable(ownable).unprotected();

        vm.prank(owner);
        DerivedHarborFixedOwnable(ownable).unprotected();

        vm.prank(owner);
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        skip(3600);

        DerivedHarborFixedOwnable(ownable).unprotected();

        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        vm.prank(owner);
        DerivedHarborFixedOwnable(ownable).unprotected();

        vm.prank(owner);
        DerivedHarborFixedOwnable(ownable).protected();
    }

    /// @notice Test that zero delayedOwner reverts with ZeroOwner
    /// @dev Permanently ownerless contracts require BaoZeroOwnable
    function test_zeroOwnerReverts() public {
        vm.expectRevert(IHarborFixedOwnable.ZeroOwner.selector);
        new DerivedHarborFixedOwnable(address(this), address(0), 3600);
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

        // Deploy via BaoFactory - msg.sender in constructor is BaoFactory, not test contract
        address ownable = _deployViaFactory(
            keccak256(abi.encode("beforeOwner.test", delay)),
            beforeOwner,
            owner,
            delay
        );

        assertEq(IHarborFixedOwnable(ownable).owner(), beforeOwner);

        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        vm.prank(beforeOwner);
        DerivedHarborFixedOwnable(ownable).protected();

        skip(delay);
        assertEq(IHarborFixedOwnable(ownable).owner(), owner);

        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        vm.prank(beforeOwner);
        DerivedHarborFixedOwnable(ownable).protected();

        vm.prank(owner);
        DerivedHarborFixedOwnable(ownable).protected();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    FACTORY/CREATE3 INTEGRATION TESTS (#26-28)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Verify that owner is the explicit beforeOwner, not the factory
    /// @dev This is the core architectural validation for HarborFixedOwnable:
    ///      when deployed via factory, msg.sender in constructor is the factory,
    ///      but owner should be the explicit beforeOwner parameter.
    function test_factoryDeploymentOwnerIsExplicit() public {
        address intendedOwner = makeAddr("intendedOwner");
        address futureOwner = makeAddr("futureOwner");
        uint256 delay = 1 hours;

        // Deploy via BaoFactory - msg.sender in constructor is BaoFactory
        address ownable = _deployViaFactory(keccak256("ownerIsExplicit"), intendedOwner, futureOwner, delay);

        // Critical assertion: owner is intendedOwner, NOT the factory address
        assertEq(IHarborFixedOwnable(ownable).owner(), intendedOwner);
        assertTrue(IHarborFixedOwnable(ownable).owner() != address(factory));

        // Factory cannot call protected functions
        vm.prank(address(factory));
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        // intendedOwner can call protected functions
        vm.prank(intendedOwner);
        DerivedHarborFixedOwnable(ownable).protected();
    }

    /// @notice Test factory deployment with immediate ownership (delay = 0)
    function test_factoryDeploymentImmediateOwnership() public {
        address intendedOwner = makeAddr("intendedOwner");

        // Deploy with zero delay - ownership transfers immediately to intendedOwner
        address ownable = _deployViaFactory(keccak256("immediateOwnership"), intendedOwner, intendedOwner, 0);

        // Owner should be intendedOwner immediately
        assertEq(IHarborFixedOwnable(ownable).owner(), intendedOwner);
        assertTrue(IHarborFixedOwnable(ownable).owner() != address(factory));

        // Factory cannot access
        vm.prank(address(factory));
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        // intendedOwner can access
        vm.prank(intendedOwner);
        DerivedHarborFixedOwnable(ownable).protected();
    }

    /// @notice Test deterministic addressing scenario (factory as deployer)
    /// @dev Validates that beforeOwner can setup the contract during delay period
    ///      before final owner takes over - this is the "stub-free" deployment pattern
    function test_factoryDeploymentSetupThenTransfer() public {
        address deployer = makeAddr("deployer"); // Script/deployer wallet
        address dao = makeAddr("dao"); // Final owner (DAO multisig)
        uint256 delay = 1 days;

        // Deploy via BaoFactory with deployer as beforeOwner, DAO as delayedOwner
        address ownable = _deployViaFactory(keccak256("setupThenTransfer"), deployer, dao, delay);

        // During delay: deployer is owner and can do setup
        assertEq(IHarborFixedOwnable(ownable).owner(), deployer);

        vm.prank(deployer);
        DerivedHarborFixedOwnable(ownable).protected(); // Setup operations succeed

        // DAO cannot access yet
        vm.prank(dao);
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        // Factory was never owner
        vm.prank(address(factory));
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        // After delay: DAO becomes owner
        skip(delay);
        assertEq(IHarborFixedOwnable(ownable).owner(), dao);

        vm.prank(dao);
        DerivedHarborFixedOwnable(ownable).protected(); // DAO can now operate

        // Deployer no longer has access
        vm.prank(deployer);
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();
    }

    /*//////////////////////////////////////////////////////////////////////////
                              EDGE CASE TESTS (#34-35)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test very large delay (1 year) - verify no overflow
    function test_veryLargeDelay() public {
        uint256 oneYear = 365 days;
        address ownable = address(new DerivedHarborFixedOwnable(address(this), owner, oneYear));

        // Before owner during the year
        assertEq(IHarborFixedOwnable(ownable).owner(), address(this));
        DerivedHarborFixedOwnable(ownable).protected();

        // Just before 1 year: still beforeOwner
        skip(oneYear - 1);
        assertEq(IHarborFixedOwnable(ownable).owner(), address(this));
        DerivedHarborFixedOwnable(ownable).protected();

        // At exactly 1 year: transitions
        skip(1);
        assertEq(IHarborFixedOwnable(ownable).owner(), owner);

        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        DerivedHarborFixedOwnable(ownable).protected();

        vm.prank(owner);
        DerivedHarborFixedOwnable(ownable).protected();
    }
}
