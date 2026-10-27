// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {HarborFixedOwnable} from "@bao/HarborFixedOwnable.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborFixedOwnable} from "@bao/interfaces/IHarborFixedOwnable.sol";

/// @dev Owned by HarborOwnable from construction: the deployer until the hand-over, the pending owner after.
contract HarborOwned is HarborOwnable {
    constructor(address deployerOwner, address pendingOwner) {
        _initializeOwner(deployerOwner, pendingOwner);
    }

    function poke() external onlyOwner {}
}

/// @dev Owned the way a proxy upgraded onto HarborOwnable is: a stored owner and no hand-over entry at all.
contract HarborOwnedWithoutAnEntry is HarborOwnable {
    constructor(address storedOwner) {
        // the owner slot as an upgraded proxy holds it: the owner, with the initialised bit covering a zero one
        assembly ("memory-safe") {
            sstore(_INITIALIZED_SLOT, or(storedOwner, shl(_BIT_INITIALIZED, iszero(storedOwner))))
        }
    }

    function poke() external onlyOwner {}
}

/// @dev The same, with roles: `pokeAsOwnerOrRole` admits the owner or role 1.
contract HarborOwnedWithRoles is HarborOwnableRoles {
    constructor(address deployerOwner, address pendingOwner) {
        _initializeOwner(deployerOwner, pendingOwner);
    }

    function pokeAsOwnerOrRole() external onlyOwnerOrRoles(1) {}

    function pokeAsRoleOrOwner() external onlyRolesOrOwner(1) {}
}

/// @dev Owned by HarborFixedOwnable: the before-owner until the delay passes, the delayed owner after.
contract FixedOwned is HarborFixedOwnable {
    constructor(
        address beforeOwner,
        address delayedOwner,
        uint256 delay
    ) HarborFixedOwnable(beforeOwner, delayedOwner, delay) {}

    function poke() external onlyOwner {}
}

/// @title HarborOwnable hands over by itself
/// @notice HarborOwnable keeps its ownership in storage and HarborFixedOwnable in immutables; otherwise they behave
///         alike: the deployer owns the contract for an hour, then the pending owner owns it, with no call needed, and
///         the deployer may hand over early. Every owner check - `onlyOwner`, the roles variant's owner-or-roles - sees
///         the same owner as `owner()`.
contract HarborOwnableTest is BaoTest {
    uint256 internal constant HAND_OVER_DELAY = 1 hours;

    address internal deployer;
    address internal pending;
    address internal stranger;
    uint256 internal deployedAt;
    HarborOwned internal owned;

    function setUp() public {
        deployer = makeAddr("deployer");
        pending = makeAddr("pending");
        stranger = makeAddr("stranger");
        deployedAt = block.timestamp;
        owned = new HarborOwned(deployer, pending);
    }

    /// @dev Right after initialisation the deployer is the owner, and the only one `onlyOwner` admits.
    function test_ownerIsTheDeployerUntilTheTransferTime() public {
        assertEq(owned.owner(), deployer, "the deployer owns it");

        vm.startPrank(deployer);
        owned.poke();
        vm.stopPrank();

        vm.startPrank(pending);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        owned.poke();
        vm.stopPrank();
    }

    /// @dev A second before the hand-over time the deployer still owns it; from that time the pending owner does, and
    ///      `onlyOwner` follows, with no call made.
    function test_ownerIsThePendingOwnerFromTheTransferTime() public {
        vm.warp(deployedAt + HAND_OVER_DELAY - 1);
        assertEq(owned.owner(), deployer, "a second before: still the deployer's");

        vm.warp(deployedAt + HAND_OVER_DELAY);
        assertEq(owned.owner(), pending, "at the time: the pending owner's");

        vm.startPrank(pending);
        owned.poke();
        vm.stopPrank();

        vm.startPrank(deployer);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        owned.poke();
        vm.stopPrank();
    }

    /// @dev The deployer may hand over before the time; from then on the pending owner owns it and the deployer is
    ///      refused.
    function test_transferOwnershipCompletesTheHandOverEarly() public {
        vm.startPrank(deployer);
        owned.transferOwnership(pending);
        vm.stopPrank();

        assertEq(owned.owner(), pending, "handed over");

        vm.startPrank(pending);
        owned.poke();
        vm.stopPrank();

        vm.startPrank(deployer);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        owned.poke();
        vm.stopPrank();
    }

    /// @dev Only the pending owner announced at initialisation can be confirmed; naming another changes nothing.
    function test_transferOwnershipRefusesAnotherConfirmOwner() public {
        vm.startPrank(deployer);
        vm.expectRevert(IHarborOwnable.CannotCompleteTransfer.selector);
        owned.transferOwnership(stranger);
        vm.stopPrank();

        assertEq(owned.owner(), deployer, "unchanged");
    }

    /// @dev The hour is when the hand-over happens, not a deadline for it: afterwards the deployer is no longer the
    ///      owner and is refused as such, while the pending owner, now the owner, may confirm the hand-over that has
    ///      already taken effect, which changes nothing.
    function test_transferOwnershipAfterTheTimeIsNotADeadline() public {
        vm.warp(deployedAt + HAND_OVER_DELAY);

        vm.startPrank(deployer);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        owned.transferOwnership(pending);
        vm.stopPrank();

        vm.startPrank(pending);
        owned.transferOwnership(pending);
        vm.stopPrank();
        assertEq(owned.owner(), pending, "the pending owner, as before the call");
    }

    /// @dev A hand-over brought forward stays put: the owner stays the owner however much time passes, and ownership
    ///      cannot be renounced by confirming the zero address, which is not the announced owner.
    function test_aCompletedHandOverStaysPut() public {
        vm.startPrank(deployer);
        owned.transferOwnership(pending);
        vm.stopPrank();

        vm.warp(deployedAt + 10 * 365 days);
        assertEq(owned.owner(), pending, "still the owner");

        vm.startPrank(pending);
        vm.expectRevert(IHarborOwnable.CannotCompleteTransfer.selector);
        owned.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(owned.owner(), pending, "still the owner");
    }

    /// @dev A contract with a stored owner and no hand-over entry - every proxy upgraded onto HarborOwnable - keeps
    ///      that owner for ever: `owner()` and `onlyOwner` answer from the stored owner, and there is nothing to
    ///      bring forward.
    function test_aContractWithNoEntryKeepsItsStoredOwner() public {
        HarborOwnedWithoutAnEntry upgraded = new HarborOwnedWithoutAnEntry(pending);

        vm.warp(deployedAt + 10 * 365 days);
        assertEq(upgraded.owner(), pending, "the stored owner");

        vm.startPrank(pending);
        upgraded.poke();
        vm.expectRevert(IHarborOwnable.CannotCompleteTransfer.selector);
        upgraded.transferOwnership(pending);
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        upgraded.poke();
        vm.stopPrank();
    }

    /// @dev The roles variant's owner-or-roles checks see the same owner as `owner()`: the deployer until the time, the
    ///      pending owner from it.
    function test_theRolesChecksFollowTheSameOwner() public {
        HarborOwnedWithRoles withRoles = new HarborOwnedWithRoles(deployer, pending);

        vm.startPrank(deployer);
        withRoles.pokeAsOwnerOrRole();
        withRoles.pokeAsRoleOrOwner();
        vm.stopPrank();
        vm.startPrank(pending);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        withRoles.pokeAsOwnerOrRole();
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        withRoles.pokeAsRoleOrOwner();
        vm.stopPrank();

        vm.warp(deployedAt + HAND_OVER_DELAY);

        vm.startPrank(pending);
        withRoles.pokeAsOwnerOrRole();
        withRoles.pokeAsRoleOrOwner();
        vm.stopPrank();
        vm.startPrank(deployer);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        withRoles.pokeAsOwnerOrRole();
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        withRoles.pokeAsRoleOrOwner();
        vm.stopPrank();
    }

    /// @dev HarborOwnable and HarborFixedOwnable, given the same deployer, pending owner and delay, report the same
    ///      owner and admit the same caller at every moment around the hand-over.
    function test_handsOverAsHarborFixedOwnableDoes() public {
        FixedOwned fixedOwned = new FixedOwned(deployer, pending, HAND_OVER_DELAY);

        uint256[3] memory moments = [deployedAt, deployedAt + HAND_OVER_DELAY - 1, deployedAt + HAND_OVER_DELAY];
        for (uint256 i = 0; i < moments.length; ++i) {
            vm.warp(moments[i]);
            assertEq(owned.owner(), fixedOwned.owner(), "the same owner");

            address admitted = fixedOwned.owner();
            address refused = admitted == deployer ? pending : deployer;
            vm.startPrank(admitted);
            owned.poke();
            fixedOwned.poke();
            vm.stopPrank();
            vm.startPrank(refused);
            vm.expectRevert(IHarborOwnable.Unauthorized.selector);
            owned.poke();
            vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
            fixedOwned.poke();
            vm.stopPrank();
        }
    }

    /// @dev Initialisation announces both transitions at once, as HarborFixedOwnable's construction does: from nobody
    ///      to the deployer, and from the deployer to the pending owner.
    function test_initialisationAnnouncesBothTransitions() public {
        vm.expectEmit(true, true, false, false);
        emit IHarborOwnable.OwnershipTransferred(address(0), deployer);
        vm.expectEmit(true, true, false, false);
        emit IHarborOwnable.OwnershipTransferred(deployer, pending);
        new HarborOwned(deployer, pending);
    }
}
