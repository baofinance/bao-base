// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stem} from "src/Stem.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Import both ownership model implementations
import {MockImplementation} from "mocks/MockImplementation.sol"; // BaoOwnable
import {MockImplementationOwnableUpgradeable} from "mocks/MockImplementationOwnableUpgradeable.sol"; // OZ Ownable

contract StemOwnershipTest is Test {
    Stem public stemImplementation;
    address public proxyAdmin = address(1);
    address public user = address(2);
    address public emergencyOwner = address(3);

    function setUp() public {
        // Deploy the Stem implementation
        stemImplementation = new Stem();
    }

    // Test 1: BaoOwnable -> Stem -> OZ Ownable
    function testBaoOwnable_to_Stem_to_OZOwnable() public {
        // 1. Start with BaoOwnable implementation
        MockImplementation baoImplementation = new MockImplementation();

        // Initialize with proxyAdmin as the pending owner
        bytes memory initData = abi.encodeWithSelector(
            MockImplementation.initialize.selector,
            proxyAdmin, // This becomes the pending owner (not immediate owner)
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(baoImplementation), initData);
        MockImplementation baoProxy = MockImplementation(address(proxy));

        // Test contract is the owner (not proxyAdmin)
        assertEq(baoProxy.owner(), address(this));

        // Transfer ownership to proxyAdmin to complete two-step ownership
        baoProxy.transferOwnership(proxyAdmin);

        // Now verify proxyAdmin is the owner
        assertEq(baoProxy.owner(), proxyAdmin);
        assertEq(baoProxy.value(), 100);

        // 2. Upgrade to Stem (emergency pause)
        vm.prank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Initialize Stem (test contract becomes owner, emergencyOwner is pending)
        bytes memory stemInitData = abi.encodeWithSelector(Stem.initialize.selector, emergencyOwner);
        (bool success, ) = address(proxy).call(stemInitData);
        require(success, "Stem initialization failed");

        // Test contract is now the owner again
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        Stem(address(proxy)).transferOwnership(emergencyOwner);

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

        vm.prank(proxyAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        ozProxy.setValue(400);
    }

    // Test 2: OZ Ownable -> Stem -> BaoOwnable
    function testOZOwnable_to_Stem_to_BaoOwnable() public {
        // 1. Start with OZ Ownable
        MockImplementationOwnableUpgradeable ozImplementation = new MockImplementationOwnableUpgradeable();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationOwnableUpgradeable.initialize.selector,
            proxyAdmin, // Owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(ozImplementation), initData);
        MockImplementationOwnableUpgradeable ozProxy = MockImplementationOwnableUpgradeable(address(proxy));

        // Verify OZ ownership model
        assertEq(ozProxy.owner(), proxyAdmin);
        assertEq(ozProxy.value(), 100);

        // 2. Upgrade to Stem
        vm.prank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Initialize Stem
        bytes memory stemInitData = abi.encodeWithSelector(Stem.initialize.selector, emergencyOwner);
        (bool success, ) = address(proxy).call(stemInitData);
        require(success, "Stem initialization failed");

        // Test contract is now the owner
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        Stem(address(proxy)).transferOwnership(emergencyOwner);

        // 3. Upgrade from Stem to BaoOwnable
        MockImplementation baoImplementation = new MockImplementation();

        vm.prank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(baoImplementation),
            abi.encodeWithSelector(
                MockImplementation.initialize.selector,
                proxyAdmin, // Pending owner
                200 // New value
            )
        );

        // 4. Verify BaoOwnable initialization
        MockImplementation baoProxy = MockImplementation(address(proxy));
        // The owner is now the test contract again
        assertEq(baoProxy.owner(), address(this));
        assertEq(baoProxy.value(), 200);

        // Transfer ownership to proxyAdmin
        baoProxy.transferOwnership(proxyAdmin);

        // Verify ownership transfer
        assertEq(baoProxy.owner(), proxyAdmin);
    }

    // Test 3: Emergency ownership transfer via Stem
    function testEmergencyOwnershipTransfer() public {
        // 1. Start with BaoOwnable implementation
        MockImplementation baoImplementation = new MockImplementation();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementation.initialize.selector,
            proxyAdmin, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(baoImplementation), initData);
        MockImplementation baoProxy = MockImplementation(address(proxy));

        // Test contract is the initial owner
        assertEq(baoProxy.owner(), address(this));

        // Transfer ownership to proxyAdmin
        baoProxy.transferOwnership(proxyAdmin);

        // Verify ownership transfer
        assertEq(baoProxy.owner(), proxyAdmin);

        // 2. Simulate compromised owner upgrading to Stem
        vm.prank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Initialize Stem with emergency owner
        bytes memory stemInitData = abi.encodeWithSelector(Stem.initialize.selector, emergencyOwner);
        (bool success, ) = address(proxy).call(stemInitData);
        require(success, "Stem initialization failed");

        // Test contract is now the immediate owner
        assertEq(Stem(address(proxy)).owner(), address(this));

        // Transfer ownership to emergencyOwner
        Stem(address(proxy)).transferOwnership(emergencyOwner);

        // 3. Verify ownership changed
        assertEq(Stem(address(proxy)).owner(), emergencyOwner);

        // 4. Original compromised owner can't upgrade
        vm.prank(proxyAdmin);
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
        MockImplementation baoImplementation = new MockImplementation();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementation.initialize.selector,
            proxyAdmin, // Pending owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(baoImplementation), initData);
        MockImplementation baoProxy = MockImplementation(address(proxy));

        // Test contract is the initial owner
        assertEq(baoProxy.owner(), address(this));

        // Transfer ownership to proxyAdmin
        baoProxy.transferOwnership(proxyAdmin);

        // Verify ownership transfer
        assertEq(baoProxy.owner(), proxyAdmin);

        // 2. Direct upgrade to OZ Ownable
        MockImplementationOwnableUpgradeable ozImplementation = new MockImplementationOwnableUpgradeable();

        vm.prank(proxyAdmin);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(ozImplementation),
            abi.encodeWithSelector(
                MockImplementationOwnableUpgradeable.initialize.selector,
                proxyAdmin, // Keep same owner
                100 // Keep same value
            )
        );

        // 3. Verify OZ Ownable works correctly
        MockImplementationOwnableUpgradeable ozProxy = MockImplementationOwnableUpgradeable(address(proxy));
        assertEq(ozProxy.owner(), proxyAdmin);
        assertEq(ozProxy.value(), 100);
    }
}
