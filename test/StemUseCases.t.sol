// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Stem} from "@bao/Stem.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Import ownership adapters
import {IOwnershipModel, IOwnershipModelFactory} from "./interfaces/IOwnershipModel.sol";
import {BaoOwnableAdapter, BaoOwnableAdapterFactory} from "./adapters/BaoOwnableAdapter.sol";
import {BaoOwnableV2Adapter, BaoOwnableV2AdapterFactory} from "./adapters/BaoOwnableV2Adapter.sol";
import {OZOwnableAdapter, OZOwnableAdapterFactory} from "./adapters/OZOwnableAdapter.sol";

/**
 * @title StemUseCasesTest
 * @notice Tests various upgrade paths and ownership transitions between different ownership models
 * @dev Uses Adapter Pattern to abstract away implementation details of different ownership models
 */
contract StemUseCasesTest is Test {
    // Ownership model factories
    BaoOwnableAdapterFactory public baoOwnableFactory;
    BaoOwnableV2AdapterFactory public baoOwnableV2Factory;
    OZOwnableAdapterFactory public ozOwnableFactory;

    // Models array for systematic testing
    IOwnershipModelFactory[] public modelFactories;
    string[] public modelNames;

    // Test addresses
    address public deployer;
    address public finalOwner;
    address public emergencyOwner;
    address public user;

    // Stem implementation
    Stem public stemImplementation;

    // Constants for test values
    uint256 constant INITIAL_VALUE = 100;
    uint256 constant UPDATED_VALUE = 200;
    uint256 constant STEM_DELAY = 0; // No delay for simplicity

    // Events to verify
    event ValueUpdated(uint256 oldValue, uint256 newValue);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        // Create test wallets
        deployer = vm.addr(1);
        finalOwner = vm.addr(2);
        emergencyOwner = vm.addr(3);
        user = vm.addr(4);

        vm.startPrank(deployer);

        // Create ownership model factories
        baoOwnableFactory = new BaoOwnableAdapterFactory();
        baoOwnableV2Factory = new BaoOwnableV2AdapterFactory();
        ozOwnableFactory = new OZOwnableAdapterFactory();

        // Initialize models and names arrays
        modelFactories.push(baoOwnableFactory);
        modelFactories.push(baoOwnableV2Factory);
        modelFactories.push(ozOwnableFactory);

        modelNames.push("BaoOwnable");
        modelNames.push("BaoOwnable_v2");
        modelNames.push("OZOwnable");

        // Deploy Stem with no delay for simplicity
        stemImplementation = new Stem(emergencyOwner, STEM_DELAY);

        vm.stopPrank();
    }

    /**
     * @notice Test all possible ownership model transitions (n²)
     */
    function testAllOwnershipTransitions() public {
        for (uint i = 0; i < modelFactories.length; i++) {
            for (uint j = 0; j < modelFactories.length; j++) {
                uint256 snapshot = vm.snapshotState();

                console2.log(string.concat("Testing transition from ", modelNames[i], " to ", modelNames[j]));

                _testOwnershipTransition(modelFactories[i], modelFactories[j]);

                vm.revertToState(snapshot);
            }
        }
    }

    /**
     * @notice Test a specific transition between two ownership models
     * @param sourceFactory The factory for the source ownership model
     * @param targetFactory The factory for the target ownership model
     */
    function _testOwnershipTransition(
        IOwnershipModelFactory sourceFactory,
        IOwnershipModelFactory targetFactory
    ) private {
        // ==== Step 1: Deploy source model via proxy ====
        vm.startPrank(deployer);

        // Deploy implementation
        IOwnershipModel sourceModel = sourceFactory.createModel(finalOwner);

        // Deploy via proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(sourceModel),
            sourceModel.getInitializationData(finalOwner, INITIAL_VALUE)
        );

        // Get adapter pointing to the proxy
        IOwnershipModel proxiedModel = sourceFactory.attachToProxy(address(proxy));

        // Complete ownership setup if needed (transfer from deployer to finalOwner)
        proxiedModel.completeOwnershipSetup();
        vm.stopPrank();

        // Verify initial state
        assertEq(proxiedModel.getValue(), INITIAL_VALUE, "Initial value should be set");
        assertEq(proxiedModel.getOwner(), finalOwner, "Final owner should be set");

        // ==== Step 2: Upgrade to Stem ====
        vm.prank(finalOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // Verify ownership after stemming
        if (STEM_DELAY > 0) {
            assertEq(Stem(address(proxy)).owner(), address(this), "Initial stem owner should be test contract");
            skip(STEM_DELAY);
        }
        assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Emergency owner should control stemmed contract");

        // ==== Step 3: Upgrade from Stem to target model ====
        vm.startPrank(emergencyOwner);

        // Deploy target implementation
        IOwnershipModel targetModel = targetFactory.createModel(finalOwner);

        // Upgrade to target model
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(targetModel),
            targetModel.getPostUpgradeSetupData(UPDATED_VALUE)
        );

        // Get adapter pointing to the updated proxy
        IOwnershipModel updatedModel = targetFactory.attachToProxy(address(proxy));
        vm.stopPrank();

        // ==== Step 4: Verify state ====
        assertEq(updatedModel.getValue(), UPDATED_VALUE, "Updated value should be correctly set");

        // Check final ownership state - depends on model
        address expectedOwner = targetFactory.getExpectedOwnerAfterUpgrade(emergencyOwner, finalOwner);
        assertEq(updatedModel.getOwner(), expectedOwner, "Owner should be set correctly after upgrade");

        // ==== Step 5: Test ownership management ====
        if (targetFactory.supportsOwnershipTransfer()) {
            // Get current owner
            address currentOwner = updatedModel.getOwner();

            // Transfer to user
            vm.prank(currentOwner);
            updatedModel.transferOwnership(user);

            // Complete transfer if needed
            updatedModel.completeOwnershipSetup();

            // Verify transfer completed
            assertEq(updatedModel.getOwner(), user, "Final ownership should transfer to user");
        }
    }

    /**
     * @notice Test upgrading directly without Stem
     */
    function testDirectUpgrades() public {
        for (uint i = 0; i < modelFactories.length; i++) {
            for (uint j = 0; j < modelFactories.length; j++) {
                if (i != j) {
                    uint256 snapshot = vm.snapshotState();

                    console2.log(string.concat("Testing direct upgrade from ", modelNames[i], " to ", modelNames[j]));

                    _testDirectUpgrade(modelFactories[i], modelFactories[j]);

                    vm.revertToState(snapshot);
                }
            }
        }
    }

    /**
     * @notice Test direct upgrade between two ownership models without using Stem
     */
    function _testDirectUpgrade(IOwnershipModelFactory sourceFactory, IOwnershipModelFactory targetFactory) private {
        // ==== Step 1: Deploy source model ====
        vm.startPrank(deployer);

        IOwnershipModel sourceModel = sourceFactory.createModel(finalOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(sourceModel),
            sourceModel.getInitializationData(finalOwner, INITIAL_VALUE)
        );
        IOwnershipModel proxiedModel = sourceFactory.attachToProxy(address(proxy));

        // Complete initial ownership setup if needed
        proxiedModel.completeOwnershipSetup();
        vm.stopPrank();

        // Verify initial state
        assertEq(proxiedModel.getValue(), INITIAL_VALUE, "Initial value should be set");
        assertEq(proxiedModel.getOwner(), finalOwner, "Final owner should be set");

        // ==== Step 2: Direct upgrade to target model ====
        vm.startPrank(finalOwner);

        IOwnershipModel targetModel = targetFactory.createModel(finalOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(targetModel),
            targetModel.getPostUpgradeSetupData(UPDATED_VALUE)
        );

        vm.stopPrank();

        // ==== Step 3: Verify upgraded state ====
        IOwnershipModel updatedModel = targetFactory.attachToProxy(address(proxy));

        assertEq(updatedModel.getValue(), UPDATED_VALUE, "Updated value should be correctly set");

        // The ownership expectations depend on the target model's behavior
        address expectedOwner = targetFactory.getExpectedOwnerAfterDirectUpgrade(finalOwner);
        assertEq(updatedModel.getOwner(), expectedOwner, "Owner should be set correctly after direct upgrade");
    }

    /**
     * @notice Test emergency recovery for each ownership model
     */
    function testEmergencyRecoveryForAllModels() public {
        for (uint i = 0; i < modelFactories.length; i++) {
            uint256 snapshot = vm.snapshotState();

            console2.log(string.concat("Testing emergency recovery for ", modelNames[i]));

            _testEmergencyRecovery(modelFactories[i]);

            vm.revertToState(snapshot);
        }
    }

    /**
     * @notice Test emergency recovery process for a specific ownership model
     */
    function _testEmergencyRecovery(IOwnershipModelFactory modelFactory) private {
        // ==== Step 1: Deploy model ====
        vm.startPrank(deployer);

        IOwnershipModel model = modelFactory.createModel(finalOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(model), model.getInitializationData(finalOwner, INITIAL_VALUE));
        IOwnershipModel proxiedModel = modelFactory.attachToProxy(address(proxy));

        // Complete initial ownership setup if needed
        proxiedModel.completeOwnershipSetup();
        vm.stopPrank();

        // ==== Step 2: Simulate emergency - upgrade to Stem ====
        vm.prank(finalOwner); // The owner upgrades to Stem in emergency
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // If STEM_DELAY > 0, wait for ownership transfer
        if (STEM_DELAY > 0) {
            skip(STEM_DELAY);
        }
        assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Emergency owner should control stemmed contract");

        // ==== Step 3: Emergency owner restores to the same model type ====
        vm.startPrank(emergencyOwner);

        IOwnershipModel recoveryModel = modelFactory.createModel(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(recoveryModel),
            recoveryModel.getInitializationData(emergencyOwner, INITIAL_VALUE)
        );

        vm.stopPrank();

        // ==== Step 4: Verify recovery ====
        IOwnershipModel recoveredModel = modelFactory.attachToProxy(address(proxy));

        // Check state was preserved/restored
        assertEq(recoveredModel.getValue(), INITIAL_VALUE, "Value should be restored");

        // Check ownership transferred to emergency owner or equivalent
        address expectedOwner = modelFactory.getExpectedOwnerAfterRecovery(emergencyOwner);
        assertEq(
            recoveredModel.getOwner(),
            expectedOwner,
            "Owner should be emergency owner or equivalent after recovery"
        );
    }

    /**
     * @notice Test that stemming properly blocks all functions
     */
    function testStemmedFunctionalityBlocked() public {
        for (uint i = 0; i < modelFactories.length; i++) {
            uint256 snapshot = vm.snapshotState();

            console2.log(string.concat("Testing stemmed functionality blocking for ", modelNames[i]));

            _testStemFunctionBlocking(modelFactories[i]);

            vm.revertToState(snapshot);
        }
    }

    /**
     * @notice Test that stemming blocks all functionality for a specific model
     */
    function _testStemFunctionBlocking(IOwnershipModelFactory modelFactory) private {
        // ==== Step 1: Deploy model ====
        vm.startPrank(deployer);

        IOwnershipModel model = modelFactory.createModel(finalOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(model), model.getInitializationData(finalOwner, INITIAL_VALUE));
        IOwnershipModel proxiedModel = modelFactory.attachToProxy(address(proxy));

        // Complete initial ownership setup if needed
        proxiedModel.completeOwnershipSetup();
        vm.stopPrank();

        // ==== Step 2: Upgrade to Stem ====
        vm.prank(finalOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");

        // ==== Step 3: Try to call functions - all should revert ====
        vm.expectRevert(); // All functions should revert
        proxiedModel.getValue();

        vm.prank(finalOwner);
        vm.expectRevert(); // All functions should revert even for owner
        proxiedModel.setValue(999);

        // ==== Step 4: Verify only Stem functions work ====
        assertEq(Stem(address(proxy)).owner(), address(this), "Should be able to call Stem's owner function");

        // If STEM_DELAY > 0, wait for ownership transfer
        if (STEM_DELAY > 0) {
            skip(STEM_DELAY);
            assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Ownership should transfer to emergency owner");
        } else {
            assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Emergency owner should be set immediately");
        }

        // ==== Step 5: Unstem and verify functionality returns ====
        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(model), // Use the same model implementation
            model.getPostUpgradeSetupData(UPDATED_VALUE)
        );
        vm.stopPrank();

        IOwnershipModel unstemmedModel = modelFactory.attachToProxy(address(proxy));
        assertEq(unstemmedModel.getValue(), UPDATED_VALUE, "Value should be updated after unstemming");
    }
}
