// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stem} from "src/Stem.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Import all ownership model implementations
import {BaoOwnableAdapter} from "test/adapters/BaoOwnableAdapter.sol"; // Adapter for BaoOwnable
import {BaoOwnable_v2Adapter} from "test/adapters/BaoOwnable_v2Adapter.sol"; // Adapter for BaoOwnable_v2
import {OZOwnableAdapter} from "test/adapters/OZOwnableAdapter.sol"; // Adapter for OZOwnable
import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol"; // Interface for ownership models
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol"; // Interface for ownership models

/**
 * @title StemParameterizedTest
 * @dev Systematic test suite for all ownership models and transitions via Stem
 */
contract StemParameterizedTest is Test {
    // Enum to represent the three ownership models we're testing
    enum OwnershipModel {
        BaoOwnable,
        BaoOwnable_v2,
        OZOwnable
    }

    // Define models at class level
    OwnershipModel[3] internal models;

    // Test configuration
    Stem public stemImplementation; // global stem implementation

    address public deployer;
    address public proxyOwner;
    address public proxyOwner2;
    address public user;
    address public emergencyOwner;

    // Constants for test values
    uint256 constant INITIAL_VALUE = 100;
    uint256 constant UPDATED_VALUE = 200;
    uint256 constant TRANSFER_DELAY = 3600; // BaoOwnable_v2 delay (1 hour)

    // Base snapshot for test isolation
    uint256 private baseSnapshot;

    function setUp() public {
        // Create test wallets
        deployer = vm.createWallet("deployer").addr;
        proxyOwner = vm.createWallet("proxyOwner").addr;
        proxyOwner2 = vm.createWallet("proxyOwner2").addr;
        emergencyOwner = vm.createWallet("emergencyOwner").addr;
        user = vm.createWallet("user").addr;

        // Deploy the Stem implementation with emergency owner and zero delay to simplify ownership
        stemImplementation = new Stem(emergencyOwner, 0);

        // Initialize models array
        models[0] = OwnershipModel.BaoOwnable;
        models[1] = OwnershipModel.BaoOwnable_v2;
        models[2] = OwnershipModel.OZOwnable;

        // Store base snapshot for all tests to revert to
        baseSnapshot = vm.snapshotState();
    }

    function createAdapter(uint modelIndex) internal returns (IOwnershipModel adapter) {
        if (models[modelIndex] == OwnershipModel.BaoOwnable) {
            adapter = new BaoOwnableAdapter();
        } else if (models[modelIndex] == OwnershipModel.BaoOwnable_v2) {
            adapter = new BaoOwnable_v2Adapter();
        } else if (models[modelIndex] == OwnershipModel.OZOwnable) {
            adapter = new OZOwnableAdapter();
        } else {
            revert("Invalid ownership model");
        }
    }

    /**
     * @dev Get model name as string (for console output)
     */
    function getModelName(uint modelIndex) internal view returns (string memory) {
        if (models[modelIndex] == OwnershipModel.BaoOwnable) {
            return "BaoOwnable";
        } else if (models[modelIndex] == OwnershipModel.BaoOwnable_v2) {
            return "BaoOwnable_v2";
        } else if (models[modelIndex] == OwnershipModel.OZOwnable) {
            return "OZOwnable";
        } else {
            return "Invalid";
        }
    }

    /**
     * @dev Test stemming behavior with all models
     */
    function testStemmingBehaviorWithAllModels() public {
        for (uint i = 0; i < models.length; i++) {
            vm.revertToState(baseSnapshot);
            console.log("Testing stemming behavior with", getModelName(i));
            _testStemmingBehavior(createAdapter(i));
        }
    }

    /**
     * @dev Test stemming behavior with a specific model
     */
    function _testStemmingBehavior(IOwnershipModel model) internal {
        // 1. Setup contract based on model
        vm.startPrank(deployer);
        model.deploy(proxyOwner, INITIAL_VALUE);
        vm.stopPrank();
        IMockImplementation proxy = model.proxy();
        skip(TRANSFER_DELAY); // do this for them all as it's harmless

        assertEq(proxy.owner(), proxyOwner, "Initial owner should be set");
        assertEq(proxy.value(), INITIAL_VALUE, "Initial value should be set");

        // 4. Stem the contract
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 5. Test that functions are stemmed
        vm.expectRevert(
            abi.encodeWithSelector(Stem.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        proxy.value(); // This should revert
        vm.expectRevert(
            abi.encodeWithSelector(Stem.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        proxy.setValue(3); // This should revert
        assertEq(proxy.owner(), emergencyOwner, "Stem ownership should transfer to emergency owner");

        // TODO: test that
        // 8. Unstem the contract (i.e put the same one back)
        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(model.implementation()), "");
        vm.stopPrank();

        assertEq(proxy.owner(), proxyOwner, "Initial owner should be reset");
        assertEq(proxy.value(), INITIAL_VALUE, "Initial value should be reset");

        vm.expectPartialRevert(model.unauthorizedSelector());
        proxy.setValue(INITIAL_VALUE + 1);

        // owner is truly re-instated
        vm.prank(proxyOwner);
        proxy.setValue(INITIAL_VALUE + 2);
        assertEq(proxy.value(), INITIAL_VALUE + 2, "Initial value should be changeable by owner");
    }

    /**
     * @dev Test all ownership transitions systematically (n^2 combinations)
     * Use proper snapshot management to avoid gas issues
     */
    function testAllOwnershipTransitions() public {
        for (uint i = 0; i < models.length; i++) {
            for (uint j = 0; j < models.length; j++) {
                vm.revertToState(baseSnapshot); // Correct revert function
                console.log("Testing transition from", getModelName(i), "to", getModelName(j));
                _testOwnershipTransition(createAdapter(i), createAdapter(j));
            }
        }
    }

    /**
     * @dev Test a specific ownership transition
     */
    function _testOwnershipTransition(OwnershipModel source, OwnershipModel target) internal {
        // 1. Setup source contract
        vm.startPrank(deployer);
        source.deploy(proxyOwner, INITIAL_VALUE);
        vm.stopPrank();
        IMockImplementation sourceProxy = source.proxy();
        skip(TRANSFER_DELAY); // do this for them all as it's harmless

        // 3. Verify initial state
        assertEq(sourceProxy.owner(), proxyOwner, "source: initial owner should be set");
        assertEq(sourceProxy.value(), INITIAL_VALUE, "source: initial value should be set");

        // 4. Upgrade to Stem
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(sourceProxy), address(stemImplementation), "");
        vm.stopPrank();
        // we know this stops anything working because of other tests

        vm.startPrank(emergencyOwner);
        target.createImplementation(proxyOwner2, UPDATED_VALUE); // not the same value
        vm.stopPrank();

        // 6. Upgrade from Stem to target implementation
        vm.startPrank(deployer);
        target.deploy(proxyOwner2, INITIAL_VALUE + 1);
        vm.stopPrank();
        IMockImplementation targetProxy = source.proxy();
        skip(TRANSFER_DELAY); // do this for them all as it's harmless

        // 7. Verify upgrade
        assertNotEq(model.implementation(), sourceImplementation, "there's a new implementation");
        assertEq(model.proxy().value(), UPDATED_VALUE, "Updated value should be set");
        assertEq(model.proxy().owner(), proxyOwner2, "Updated value should be set");
    }

    // /**
    //  * @dev Specific test for BaoOwnable_v2 automatic ownership transfer
    //  */
    // function testBaoOwnableV2AutoTransfer() public {
    //     // 1. Deploy BaoOwnable_v2 implementation
    //     address originalOwner = vm.createWallet("originalOwner").addr;
    //     MockImplementationWithState_v2 implementation = new MockImplementationWithState_v2(originalOwner);
    //     ERC1967Proxy proxy = new ERC1967Proxy(
    //         address(implementation),
    //         abi.encodeWithSelector(MockImplementationWithState_v2.initialize.selector, INITIAL_VALUE)
    //     );
    //     MockImplementationWithState_v2 proxied = MockImplementationWithState_v2(address(proxy));

    //     // 2. Verify initial ownership
    //     assertEq(proxied.owner(), address(this), "Initial owner should be test contract");
    //     assertEq(proxied.value(), INITIAL_VALUE, "Initial value should be set");

    //     // 7. Transfer ownership to original owner
    //     // also check the stem
    //     assertEq(stemImplementation.owner(), address(this), "Stem owner should still be test contract");
    //     skip(STEM_TRANSFER_DELAY);
    //     assertEq(stemImplementation.owner(), emergencyOwner, "Stem owner should now be emergencyOwner");
    //     skip(TRANSFER_DELAY); // skip again in case the ownable delay is longer
    //     assertEq(proxied.owner(), originalOwner, "Owner should be now be new original owner");

    //     // all good

    //     // 3. Stem the contract
    //     vm.startPrank(originalOwner); // only the original owner can now stem.
    //     UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
    //     vm.stopPrank();
    //     // as we waited before for the stem to transfer ownerhip before, the proxy is now immediately is owned by the emergency owner
    //     assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Stem ownership should transfer to emergency owner");

    //     // 5. Unstem with a new BaoOwnable_v2 implementation
    //     address newOwner = vm.createWallet("newOwner").addr;
    //     MockImplementationWithState_v2 newImpl = new MockImplementationWithState_v2(newOwner);

    //     vm.startPrank(emergencyOwner);
    //     UnsafeUpgrades.upgradeProxy(
    //         address(proxy),
    //         address(newImpl),
    //         "" // can only do initialisation now with the deployer - that's who owns the implementation, atm!
    //     );
    //     vm.stopPrank();
    //     assertEq(proxied.value(), INITIAL_VALUE, "Value should be as before");
    //     proxied.postUpgradeSetup(UPDATED_VALUE);

    //     // 6. Verify new state
    //     assertEq(proxied.owner(), address(this), "Owner should be deployer");
    //     assertEq(proxied.value(), UPDATED_VALUE, "Value should be updated");

    //     // 7. Transfer ownership to new owner
    //     skip(TRANSFER_DELAY);
    //     assertEq(proxied.owner(), newOwner, "Owner should be new owner");
    // }

    // /**
    //  * @dev Test direct transitions between ownership models without Stem
    //  */
    // function testDirectOwnershipTransitions() public {
    //     // Test each source → target direct transition
    //     for (uint i = 0; i < models.length; i++) {
    //         for (uint j = 0; j < models.length; j++) {
    //             if (i != j) {
    //                 vm.revertToState(baseSnapshot);
    //                 console.log(
    //                     "Testing direct transition from",
    //                     getModelName(models[i]),
    //                     "to",
    //                     getModelName(models[j])
    //                 );
    //                 testDirectTransition(models[i], models[j]);
    //             }
    //         }
    //     }
    // }

    // /**
    //  * @dev Test direct transition between two ownership models
    //  */
    // function testDirectTransition(OwnershipModel source, OwnershipModel target) internal {
    //     // 1. Setup source contract
    //     address impl = deployImplementation(source, proxyOwner);
    //     bytes memory initData = getInitData(source, proxyOwner);
    //     ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

    //     // 2. Handle initial ownership setup
    //     setupOwnership(address(proxy), source, proxyOwner);

    //     // 3. Verify initial state
    //     assertEq(getValue(address(proxy), source), INITIAL_VALUE, "Initial value should be set");

    //     // 4. Direct upgrade to target implementation
    //     address targetImpl = deployImplementation(target, proxyOwner);
    //     bytes memory targetInitData = getUpgradeData(target);

    //     vm.startPrank(proxyOwner);
    //     UnsafeUpgrades.upgradeProxy(address(proxy), targetImpl, targetInitData);
    //     vm.stopPrank();

    //     // 5. Verify final state
    //     assertEq(getValue(address(proxy), target), UPDATED_VALUE, "Updated value should be set");

    //     if (target == OwnershipModel.BaoOwnable) {
    //         assertEq(getOwner(address(proxy), target), address(this), "Owner should be test contract for BaoOwnable");
    //     } else if (target == OwnershipModel.BaoOwnable_v2) {
    //         assertEq(
    //             getOwner(address(proxy), target),
    //             address(this),
    //             "Owner should be test contract for BaoOwnable_v2"
    //         );
    //     } else if (target == OwnershipModel.OZOwnable) {
    //         assertEq(getOwner(address(proxy), target), proxyOwner, "Owner should be proxyOwner for OZOwnable");
    //     }
    // }

    // /**
    //  * @dev Call postUpgradeSetup for any implementation
    //  */
    // function callPostUpgradeSetup(address proxy, OwnershipModel model, uint256 newValue, address proxyOwner_) internal {
    //     vm.startPrank(proxyOwner_);
    //     if (model == OwnershipModel.BaoOwnable) {
    //         MockImplementationWithState(proxy).postUpgradeSetup(newValue);
    //     } else if (model == OwnershipModel.BaoOwnable_v2) {
    //         MockImplementationWithState_v2(proxy).postUpgradeSetup(newValue);
    //     } else if (model == OwnershipModel.OZOwnable) {
    //         MockImplementationOZOwnable(proxy).postUpgradeSetup(newValue);
    //     }
    //     vm.stopPrank();
    // }

    // /**
    //  * @dev Test post-upgrade setup functionality across all models
    //  */
    // function testPostUpgradeSetupWithAllModels() public {
    //     for (uint i = 0; i < models.length; i++) {
    //         vm.revertToState(baseSnapshot);
    //         console.log("Testing postUpgradeSetup with", getModelName(models[i]));
    //         testPostUpgradeSetup(models[i]);
    //     }
    // }

    // /**
    //  * @dev Test post-upgrade setup with a specific model
    //  */
    // function testPostUpgradeSetup(OwnershipModel model) internal {
    //     // 1. Setup contract based on model
    //     address impl = deployImplementation(model, proxyOwner);
    //     bytes memory initData = getInitData(model, proxyOwner);
    //     ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

    //     // 2. Handle ownership setup
    //     setupOwnership(address(proxy), model, proxyOwner);

    //     // 3. Verify initial state
    //     assertEq(getValue(address(proxy), model), INITIAL_VALUE, "Initial value should be set");

    //     // 4. Stem the contract
    //     vm.startPrank(proxyOwner);
    //     UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
    //     vm.stopPrank();

    //     // 5. Wait for ownership transfer if needed
    //     if (model == OwnershipModel.BaoOwnable || model == OwnershipModel.BaoOwnable_v2) {
    //         skip(TRANSFER_DELAY);
    //     }

    //     // 6. Unstem to the same model
    //     address newImpl = deployImplementation(model, proxyOwner);

    //     vm.startPrank(emergencyOwner);
    //     UnsafeUpgrades.upgradeProxy(address(proxy), newImpl, "");
    //     vm.stopPrank();

    //     // 7. Use postUpgradeSetup to set a new value
    //     callPostUpgradeSetup(address(proxy), model, UPDATED_VALUE, emergencyOwner);

    //     // 8. Verify the value was updated
    //     assertEq(getValue(address(proxy), model), UPDATED_VALUE, "Value should be updated via postUpgradeSetup");
    // }

    // /**
    //  * @dev Test complex state operations similar to what was tested in testComplexStateTransfer
    //  */
    // function testComplexStateTransferWithAllModels() public {
    //     for (uint i = 0; i < models.length; i++) {
    //         vm.revertToState(baseSnapshot);
    //         console.log("Testing complex state transfer with", getModelName(models[i]));
    //         testComplexStateTransfer(models[i]);
    //     }
    // }

    // /**
    //  * @dev Test complex state transfer operations
    //  */
    // function testComplexStateTransfer(OwnershipModel model) internal {
    //     // 1. Setup initial contract
    //     address impl = deployImplementation(model, proxyOwner);
    //     bytes memory initData = getInitData(model, proxyOwner);
    //     ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

    //     // 2. Setup ownership
    //     setupOwnership(address(proxy), model, proxyOwner);

    //     // 3. Make state changes if model supports it
    //     if (model == OwnershipModel.BaoOwnable) {
    //         vm.prank(proxyOwner);
    //         MockImplementationWithState(address(proxy)).incrementValue();
    //         assertEq(getValue(address(proxy), model), INITIAL_VALUE + 1, "Value should be incremented");
    //     } else if (model == OwnershipModel.BaoOwnable_v2) {
    //         vm.prank(proxyOwner);
    //         MockImplementationWithState_v2(address(proxy)).incrementValue();
    //         assertEq(getValue(address(proxy), model), INITIAL_VALUE + 1, "Value should be incremented");
    //     } else {
    //         // For OZ model, just set a new value
    //         vm.prank(proxyOwner);
    //         MockImplementationOZOwnable(address(proxy)).setValue(INITIAL_VALUE + 1);
    //         assertEq(getValue(address(proxy), model), INITIAL_VALUE + 1, "Value should be updated");
    //     }

    //     // 4. Pause by upgrading to Stem
    //     vm.startPrank(proxyOwner);
    //     UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
    //     vm.stopPrank();

    //     // 5. Wait for ownership transfer if needed
    //     if (model == OwnershipModel.BaoOwnable || model == OwnershipModel.BaoOwnable_v2) {
    //         skip(TRANSFER_DELAY);
    //     }

    //     // 6. Upgrade from Stem to same implementation type but new instance
    //     address newImpl = deployImplementation(model, proxyOwner);

    //     vm.startPrank(emergencyOwner);
    //     UnsafeUpgrades.upgradeProxy(address(proxy), newImpl, "");
    //     vm.stopPrank();

    //     // 7. Set up the new implementation after upgrade using postUpgradeSetup
    //     callPostUpgradeSetup(address(proxy), model, UPDATED_VALUE, emergencyOwner);

    //     // 8. Verify enhanced functionality works with expected value
    //     assertEq(getValue(address(proxy), model), UPDATED_VALUE, "Value should be updated after postUpgradeSetup");
    // }
}
