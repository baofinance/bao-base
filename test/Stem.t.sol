// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stem} from "src/Stem.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock contracts for testing
import {MockImplementation} from "mocks/MockImplementation.sol";
import {MockImplementationWithState} from "mocks/MockImplementationWithState.sol";
import {MockImplementationWithImmutables} from "mocks/MockImplementationWithImmutables.sol";

contract StemTest is Test {
    Stem public stemImplementation;
    address public proxyAdmin = address(1);
    address public user = address(2);
    address public emergencyOwner = address(3);

    function setUp() public {
        // Deploy the Stem implementation
        stemImplementation = new Stem();
    }

    // --- SCENARIO 1: EMERGENCY PAUSE TESTS (SAME OWNER) ---

    function testEmergencyPauseSameOwner() public {
        // 1. Start with a running implementation
        MockImplementationWithState actualImplementation = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyAdmin, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(actualImplementation), initData);
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // Test contract is the owner, not proxyAdmin
        assertEq(implementation.owner(), address(this));

        // Transfer ownership to proxyAdmin
        implementation.transferOwnership(proxyAdmin);

        // Now proxyAdmin is the owner
        assertEq(implementation.owner(), proxyAdmin);

        // System is running
        assertEq(implementation.value(), 100);

        // Increase value (normal operation)
        vm.prank(proxyAdmin);
        implementation.incrementValue();
        assertEq(implementation.value(), 101);

        // 2. Emergency! Upgrade to Stem to pause functionality
        vm.startPrank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 3. Now the proxy points to Stem - verify specific stemmed behavior

        // First, verify implementation address changed
        assertEq(UnsafeUpgrades.getImplementationAddress(address(proxy)), address(stemImplementation));

        // Now test that the stemmed function reverts with a specific pattern
        // No specific selector available - this should produce a function not found error
        bytes4 valueSelector = implementation.value.selector;

        // Option 1: Verify function call reverts with proper function selector mismatch
        vm.expectRevert();
        implementation.incrementValue();

        // Option 2: Try a low-level call to verify the exact error - will return false for failure
        (bool success, ) = address(implementation).call(abi.encodeWithSelector(valueSelector));
        assertFalse(success, "Call to stemmed function should fail");

        // Test direct call to another function
        vm.expectRevert();
        implementation.value();

        // 5. Upgrade back from Stem to fixed implementation
        MockImplementationWithState fixedImplementation = new MockImplementationWithState();
        vm.startPrank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(fixedImplementation), "");
        vm.stopPrank();
    }

    // --- SCENARIO 2: EMERGENCY PAUSE TESTS (DIFFERENT OWNER) ---

    function testEmergencyPauseDifferentOwner() public {
        // 1. Start with a running implementation
        MockImplementationWithState actualImplementation = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyAdmin, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(actualImplementation), initData);
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // Test contract is the owner, not proxyAdmin
        assertEq(implementation.owner(), address(this));

        // Transfer ownership to proxyAdmin
        implementation.transferOwnership(proxyAdmin);

        // Now proxyAdmin is the owner
        assertEq(implementation.owner(), proxyAdmin);

        // 2. EMERGENCY! Original owner (proxyAdmin) is compromised!
        // Deploy new Stem and upgrade to it with new secure owner
        Stem newStem = new Stem();

        vm.startPrank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(newStem), "");
        vm.stopPrank();

        // Initialize Stem with a new secure owner
        bytes memory stemInitData = abi.encodeWithSelector(Stem.initialize.selector, emergencyOwner);
        (bool success, ) = address(proxy).call(stemInitData);
        require(success, "Stem initialization failed");

        // Test contract is now the owner
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        Stem(address(proxy)).transferOwnership(emergencyOwner);

        // Now emergencyOwner is the owner
        assertEq(Stem(address(proxy)).owner(), emergencyOwner);

        // 5. New emergency owner can upgrade to fixed implementation
        MockImplementationWithState fixedImplementation = new MockImplementationWithState();

        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(fixedImplementation), "");
        vm.stopPrank();

        // 6. State is preserved, but ownership is now the emergency owner
        assertEq(implementation.value(), 100);

        // 7. Emergency owner can transfer ownership back to the original owner (if desired)
        vm.prank(emergencyOwner);
        implementation.transferOwnership(proxyAdmin);

        // Ownership is transferred
        assertEq(implementation.owner(), proxyAdmin);
    }

    // --- ADDITIONAL SCENARIOS WITH IMMUTABLES AND STATE CHANGES ---

    function testUpgradeWithImmutables() public {
        // 1. Start with Stem proxy
        bytes memory initData = abi.encodeWithSelector(Stem.initialize.selector, proxyAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(stemImplementation), initData);
        Stem stemProxy = Stem(address(proxy));

        // Test contract is the owner
        assertEq(stemProxy.owner(), address(this));

        // Transfer ownership to proxyAdmin
        stemProxy.transferOwnership(proxyAdmin);

        // Now proxyAdmin is the owner
        assertEq(stemProxy.owner(), proxyAdmin);

        // 2. Upgrade to implementation with immutables
        MockImplementationWithImmutables immutableImpl = new MockImplementationWithImmutables(999);

        vm.startPrank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(stemProxy), address(immutableImpl), "");
        vm.stopPrank();

        // 3. Verify immutable values are preserved
        MockImplementationWithImmutables proxiedImpl = MockImplementationWithImmutables(address(proxy));
        assertEq(proxiedImpl.immutableValue(), 999);

        // 4. Initialize state variables - no longer needed as initialization happens in the upgrade step

        // 5. Verify both immutable and state values work
        assertEq(proxiedImpl.immutableValue(), 999); // Immutable from implementation
        assertEq(proxiedImpl.stateValue(), 123); // State from proxy storage
    }

    function testComplexStateTransfer() public {
        // 1. Deploy starter implementation and initialize
        MockImplementationWithState initialImpl = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyAdmin, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(initialImpl), initData);
        MockImplementationWithState proxiedImpl = MockImplementationWithState(address(proxy));

        // Test contract is the owner
        assertEq(proxiedImpl.owner(), address(this));

        // Transfer ownership to proxyAdmin
        proxiedImpl.transferOwnership(proxyAdmin);

        // Now proxyAdmin is the owner
        assertEq(proxiedImpl.owner(), proxyAdmin);

        // 2. Make state changes
        vm.prank(proxyAdmin);
        proxiedImpl.incrementValue();
        assertEq(proxiedImpl.value(), 101);

        // 3. Pause by upgrading to Stem
        vm.startPrank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 4. Deploy enhanced implementation
        MockImplementation enhancedImpl = new MockImplementation();

        // 5. Upgrade from Stem to enhanced implementation
        vm.startPrank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(enhancedImpl), "");
        vm.stopPrank();

        // Test contract is now the owner again if using BaoOwnable pattern in MockImplementation
        // Need to transfer ownership or use the test contract for further operations

        // 6. Set up the new implementation after upgrade
        vm.prank(proxyAdmin);
        MockImplementation(address(proxy)).postUpgradeSetup(999);

        // 7. Verify enhanced functionality works with expected value
        assertEq(MockImplementation(address(proxy)).value(), 999);
    }

    // Add a new test specifically for testing stemmed function behavior
    function testStemmedFunctionBehavior() public {
        // Deploy a contract that will be stemmed
        MockImplementationWithState initialImpl = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            address(this), // Owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(initialImpl), initData);
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // Verify it works initially
        assertEq(implementation.value(), 100);

        // Stem it
        UnsafeUpgrades.upgradeProxy(address(implementation), address(stemImplementation), "");

        // Try different types of calls to verify stemming behavior

        // 1. Function that existed in original implementation
        vm.expectRevert(); // Should revert without a specific reason (function not found)
        implementation.value();

        // 2. Function that modifies state
        vm.expectRevert();
        implementation.incrementValue();

        // 3. Try a non-existent function (both on original impl and on Stem)
        bytes4 nonExistentSelector = bytes4(keccak256("nonExistentFunction()"));
        (bool success, ) = address(implementation).call(abi.encodeWithSelector(nonExistentSelector));
        assertFalse(success, "Call to non-existent function should fail");

        // 4. Only owner functions should still work on the Stem implementation
        Stem stemmedImpl = Stem(address(proxy));
        assertEq(stemmedImpl.owner(), address(this));

        // 5. Can upgrade again from Stem to a new implementation
        MockImplementationWithState newImpl = new MockImplementationWithState();
        vm.startPrank(address(this));
        UnsafeUpgrades.upgradeProxy(address(proxy), address(newImpl), "");
        vm.stopPrank();

        // 6. Should work again after unstemming
        assertEq(implementation.value(), 100); // State is preserved
    }
}
