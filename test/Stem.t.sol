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
    address proxyOwner = vm.createWallet("proxyOwner").addr;
    address user = vm.createWallet("user").addr;
    address emergencyOwner = vm.createWallet("emergencyOwner").addr;

    function setUp() public {
        // Deploy the Stem implementation
        stemImplementation = new Stem(emergencyOwner, 100);
    }

    // --- SCENARIO 1: EMERGENCY PAUSE TESTS (SAME OWNER) ---

    function testEmergencyPauseSameOwner() public {
        // 1. Start with a running implementation
        MockImplementationWithState actualImplementation = new MockImplementationWithState();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(actualImplementation),
            abi.encodeWithSelector(
                MockImplementationWithState.initialize.selector,
                proxyOwner, // Pending owner
                100 // Initial value
            )
        );
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // Test contract is the deployer, not owner
        assertEq(implementation.owner(), address(this));

        // Transfer ownership to owner
        implementation.transferOwnership(proxyOwner);

        // Now owner is the owner
        assertEq(implementation.owner(), proxyOwner);

        // System is running
        assertEq(implementation.value(), 100);

        // Increase value (normal operation)
        vm.prank(proxyOwner);
        implementation.incrementValue();
        assertEq(implementation.value(), 101);

        // 2. Emergency! Upgrade to Stem to pause functionality
        vm.startPrank(proxyOwner);
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
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(fixedImplementation), "");
        vm.stopPrank();
    }

    // --- SCENARIO 2: EMERGENCY PAUSE TESTS (DIFFERENT OWNER) ---

    function testEmergencyPauseDifferentOwner() public {
        // 1. Start with a running implementation
        MockImplementationWithState actualImplementation = new MockImplementationWithState();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(actualImplementation),
            abi.encodeWithSelector(
                MockImplementationWithState.initialize.selector,
                proxyOwner, // Pending owner
                100 // Initial value
            )
        );
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // Test contract is the owner, not owner
        assertEq(implementation.owner(), address(this));

        // Transfer ownership to owner
        implementation.transferOwnership(proxyOwner);

        // Now owner is the owner
        assertEq(implementation.owner(), proxyOwner);

        // 2. EMERGENCY! Original owner (proxyOwner) is compromised!
        // Deploy new Stem and upgrade to it with new secure owner
        Stem newStem = new Stem(emergencyOwner, 100);

        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(newStem), "");
        vm.stopPrank();

        // Test contract is now the owner
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        skip(100);

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
        implementation.transferOwnership(proxyOwner);

        // Ownership is transferred
        assertEq(implementation.owner(), proxyOwner);
    }

    // --- ADDITIONAL SCENARIOS WITH IMMUTABLES AND STATE CHANGES ---

    function testUpgradeWithImmutables() public {
        // 1. Start with Stem proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(stemImplementation), "");
        Stem stemProxy = Stem(address(proxy));

        // Test contract is the owner
        assertEq(stemProxy.owner(), address(this));

        // Transfer ownership to owner
        skip(100);

        // Now owner is the owner
        assertEq(stemProxy.owner(), proxyOwner);

        // 2. Upgrade to implementation with immutables
        MockImplementationWithImmutables immutableImpl = new MockImplementationWithImmutables(999);

        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(stemProxy), address(immutableImpl), "");
        vm.stopPrank();

        // 3. Verify immutable values are preserved
        MockImplementationWithImmutables proxiedImpl = MockImplementationWithImmutables(address(proxy));
        assertEq(proxiedImpl.immutableValue(), 999);

        // 4. Initialize state variables
        vm.prank(proxyOwner);
        proxiedImpl.setStateValue(123); // Add this line to set the state value

        // 5. Verify both immutable and state values work
        assertEq(proxiedImpl.immutableValue(), 999); // Immutable from implementation
        assertEq(proxiedImpl.stateValue(), 123); // State from proxy storage
    }

    function testComplexStateTransfer() public {
        // 1. Deploy starter implementation and initialize
        MockImplementationWithState initialImpl = new MockImplementationWithState();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(initialImpl),
            abi.encodeWithSelector(
                MockImplementationWithState.initialize.selector,
                proxyOwner, // Pending owner
                100 // Initial value
            )
        );
        MockImplementationWithState proxiedImpl = MockImplementationWithState(address(proxy));

        // Test contract is the owner
        assertEq(proxiedImpl.owner(), address(this));

        // Transfer ownership to owner
        proxiedImpl.transferOwnership(proxyOwner);

        // Now owner is the owner
        assertEq(proxiedImpl.owner(), proxyOwner);

        // 2. Make state changes
        vm.prank(proxyOwner);
        proxiedImpl.incrementValue();
        assertEq(proxiedImpl.value(), 101);

        // 3. Pause by upgrading to Stem
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 4. Deploy enhanced implementation (same type but new instance)
        MockImplementationWithState enhancedImpl = new MockImplementationWithState();

        // 5. Upgrade from Stem to enhanced implementation
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(enhancedImpl), "");
        vm.stopPrank();

        // 6. Set up the new implementation after upgrade
        vm.prank(proxyOwner);
        MockImplementationWithState(address(proxy)).postUpgradeSetup(999);

        // 7. Verify enhanced functionality works with expected value
        assertEq(MockImplementationWithState(address(proxy)).value(), 999);
    }

    // Add a new test specifically for testing stemmed function behavior
    function testStemmedFunctionBehavior() public {
        // Deploy a contract that will be stemmed
        MockImplementationWithState initialImpl = new MockImplementationWithState();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(initialImpl),
            abi.encodeWithSelector(
                MockImplementationWithState.initialize.selector,
                address(this), // Owner
                100 // Initial value
            )
        );
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
