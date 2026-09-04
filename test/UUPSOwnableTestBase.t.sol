// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IOwnable} from "@bao/interfaces/IOwnable.sol";

/// @title UUPSOwnableTestBase
/// @notice Reusable behaviour suite for the upgrade/initialisation surface of any
///         owner-authorised UUPS proxy (`_authorizeUpgrade` gated by the Bao/Harbor
///         ownership mixins). Override `_uupsProxyTarget` (the deployed proxy, owned by this
///         test contract), `_uupsNonOwner`, and `_uupsCallInitialize` (invoke the contract's
///         own `initialize` on an arbitrary target); inherit the four tests. Upgrades are
///         exercised by re-upgrading to the CURRENT implementation (read from the ERC1967
///         slot), so concretes need no second implementation fixture.
abstract contract UUPSOwnableTestBase is Test {
    /// @dev ERC1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
    bytes32 private constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev The deployed UUPS proxy under test, owned by this test contract.
    function _uupsProxyTarget() internal view virtual returns (address);

    /// @dev An address that does NOT own the proxy.
    function _uupsNonOwner() internal view virtual returns (address);

    /// @dev Call the contract's own `initialize(...)` on `target` with arbitrary valid
    ///      arguments. Must be a SINGLE external call (tests wrap it in `vm.expectRevert`,
    ///      which binds to the next call).
    function _uupsCallInitialize(address target) internal virtual;

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ERC1967_IMPLEMENTATION_SLOT))));
    }

    /// @notice A non-owner cannot upgrade: _authorizeUpgrade reverts Unauthorized before any
    ///         implementation change.
    function test_uups_upgradeByNonOwner_reverts() public {
        address proxy = _uupsProxyTarget();
        address implementation = _implementationOf(proxy);

        vm.startPrank(_uupsNonOwner());
        vm.expectRevert(IOwnable.Unauthorized.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(implementation, "");
        vm.stopPrank();
    }

    /// @notice The owner can upgrade (exercised as an upgrade to the current implementation,
    ///         which passes the ERC1822 proxiableUUID check and leaves the slot intact).
    function test_uups_upgradeByOwner_succeeds() public {
        address proxy = _uupsProxyTarget();
        address implementation = _implementationOf(proxy);

        UUPSUpgradeable(proxy).upgradeToAndCall(implementation, "");

        assertEq(_implementationOf(proxy), implementation, "implementation slot intact");
    }

    /// @notice initialize cannot be called a second time on the proxy.
    function test_uups_initializeTwice_reverts() public {
        address proxy = _uupsProxyTarget();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _uupsCallInitialize(proxy);
    }

    /// @notice initialize cannot be called on the raw implementation (its constructor ran
    ///         _disableInitializers), so it can never be commandeered as its own contract.
    function test_uups_initializeImplementation_reverts() public {
        address implementation = _implementationOf(_uupsProxyTarget());

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _uupsCallInitialize(implementation);
    }
}
