// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stem} from "src/Stem.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Import ownership model implementations
import {MockImplementationWithState} from "mocks/MockImplementationWithState.sol"; // BaoOwnable
import {MockImplementationWithState_v2} from "mocks/MockImplementationWithState_v2.sol"; // BaoOwnable_v2
import {MockImplementationOwnableUpgradeable} from "mocks/MockImplementationOwnableUpgradeable.sol"; // OZ Ownable

contract StemOwnershipTest is Test {
    Stem public stemImplementation;
    address public proxyOwner = address(1);
    address public user = address(2);
    address public emergencyOwner = address(3);

    function setUp() public {
        // Deploy the Stem implementation
        stemImplementation = new Stem(emergencyOwner, 100);
    }

    // Test 1: BaoOwnable -> Stem -> OZ Ownable
    function testBaoOwnable_to_Stem_to_OZOwnable() public {
        // 1. Start with BaoOwnable implementation
        MockImplementationWithState baoImplementation = new MockImplementationWithState();

        // Initialize with proxyOwner as the pending owner
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyOwner, // This becomes the pending owner (not immediate owner)
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(baoImplementation), initData);
        MockImplementationWithState baoProxy = MockImplementationWithState(address(proxy));

        // Test contract is the owner (not proxyOwner)
        assertEq(baoProxy.owner(), address(this));

        // Transfer ownership to proxyOwner to complete two-step ownership
        baoProxy.transferOwnership(proxyOwner);

        // Now verify proxyOwner is the owner
        assertEq(baoProxy.owner(), proxyOwner);
        assertEq(baoProxy.value(), 100);

        // 2. Upgrade to Stem (emergency pause)
        vm.prank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Test contract is now the owner again
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        skip(100);

        // Verify ownership transfer
        assertEq(Stem(address(proxy)).owner(), emergencyOwner);

        // 3. Upgrade from Stem to OZ Ownable
        MockImplementationOwnableUpgradeable ozImplementation = new MockImplementationOwnableUpgradeable();

        vm.prank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(ozImplementation),
            abi.encodeWithSelector(
                MockImplementationOwnableUpgradeable.initialize.selector,
                emergencyOwner, // Owner
                200 // New value
            )
        );

        // 4. Verify OZ Ownable works correctly
        MockImplementationOwnableUpgradeable ozProxy = MockImplementationOwnableUpgradeable(address(proxy));
        assertEq(ozProxy.owner(), emergencyOwner);
        assertEq(ozProxy.value(), 200);

        // Test permissions
        vm.prank(emergencyOwner);
        ozProxy.setValue(300);
        assertEq(ozProxy.value(), 300);

        vm.prank(proxyOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        ozProxy.setValue(400);
    }

    // Test 2: OZ Ownable -> Stem -> BaoOwnable
    function testOZOwnable_to_Stem_to_BaoOwnable() public {
        // 1. Start with OZ Ownable
        MockImplementationOwnableUpgradeable ozImplementation = new MockImplementationOwnableUpgradeable();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationOwnableUpgradeable.initialize.selector,
            proxyOwner, // Owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(ozImplementation), initData);
        MockImplementationOwnableUpgradeable ozProxy = MockImplementationOwnableUpgradeable(address(proxy));

        // Verify OZ ownership model
        assertEq(ozProxy.owner(), proxyOwner);
        assertEq(ozProxy.value(), 100);

        // 2. Upgrade to Stem
        vm.prank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Test contract is now the owner
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        skip(100);

        // 3. Upgrade from Stem to BaoOwnable
        MockImplementationWithState baoImplementation = new MockImplementationWithState();

        vm.prank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(baoImplementation),
            abi.encodeWithSelector(
                MockImplementationWithState.initialize.selector,
                proxyOwner, // Pending owner
                200 // New value
            )
        );

        // 4. Verify BaoOwnable initialization
        MockImplementationWithState baoProxy = MockImplementationWithState(address(proxy));
        // The owner is now the test contract again
        assertEq(baoProxy.owner(), address(this));
        assertEq(baoProxy.value(), 200);

        // Transfer ownership to proxyOwner
        baoProxy.transferOwnership(proxyOwner);

        // Verify ownership transfer
        assertEq(baoProxy.owner(), proxyOwner);
    }

    // Test 3: Emergency ownership transfer via Stem
    function testEmergencyOwnershipTransfer() public {
        // 1. Start with BaoOwnable implementation
        MockImplementationWithState baoImplementation = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyOwner, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(baoImplementation), initData);
        MockImplementationWithState baoProxy = MockImplementationWithState(address(proxy));

        // Test contract is the initial owner
        assertEq(baoProxy.owner(), address(this));

        // Transfer ownership to proxyOwner
        baoProxy.transferOwnership(proxyOwner);

        // Verify ownership transfer
        assertEq(baoProxy.owner(), proxyOwner);

        // 2. Simulate compromised owner upgrading to Stem
        vm.prank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Test contract is now the immediate owner
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        skip(100);

        // 3. Verify ownership changed
        assertEq(Stem(address(proxy)).owner(), emergencyOwner);

        // 4. Original compromised owner can't upgrade
        vm.prank(proxyOwner);
        vm.expectRevert("BaoOwnable: caller is not the owner");
        UnsafeUpgrades.upgradeProxy(address(proxy), address(0x123), "");

        // 5. Emergency owner can upgrade to OZ Ownable
        MockImplementationOwnableUpgradeable ozImplementation = new MockImplementationOwnableUpgradeable();

        vm.prank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(ozImplementation),
            abi.encodeWithSelector(MockImplementationOwnableUpgradeable.initialize.selector, emergencyOwner, 200)
        );

        // 6. Verify new implementation works with emergency owner
        MockImplementationOwnableUpgradeable ozProxy = MockImplementationOwnableUpgradeable(address(proxy));
        assertEq(ozProxy.owner(), emergencyOwner);
        assertEq(ozProxy.value(), 200);
    }

    // Test 4: BaoOwnable -> OZ Ownable direct migration
    function testBaoOwnable_to_OZOwnable_Direct() public {
        // 1. Start with BaoOwnable implementation
        MockImplementationWithState baoImplementation = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyOwner, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(baoImplementation), initData);
        MockImplementationWithState baoProxy = MockImplementationWithState(address(proxy));

        // Test contract is the initial owner
        assertEq(baoProxy.owner(), address(this));

        // Transfer ownership to proxyOwner
        baoProxy.transferOwnership(proxyOwner);

        // Verify ownership transfer
        assertEq(baoProxy.owner(), proxyOwner);

        // 2. Direct upgrade to OZ Ownable
        MockImplementationOwnableUpgradeable ozImplementation = new MockImplementationOwnableUpgradeable();

        vm.prank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(ozImplementation),
            abi.encodeWithSelector(
                MockImplementationOwnableUpgradeable.initialize.selector,
                proxyOwner, // Keep same owner
                100 // Keep same value
            )
        );

        // 3. Verify OZ Ownable works correctly
        MockImplementationOwnableUpgradeable ozProxy = MockImplementationOwnableUpgradeable(address(proxy));
        assertEq(ozProxy.owner(), proxyOwner);
        assertEq(ozProxy.value(), 100);
    }
}
