// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
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
 * @title StemUseCasesTest
 * @dev Systematic test suite for all ownership models and transitions via Stem
 */
contract StemUseCasesTest is Test {
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

    function _deploy(
        IOwnershipModel model,
        address deployer_,
        address owner_,
        uint256 initialValue
    ) internal returns (address proxy, address implementation) {
        // 1. Setup contract based on model
        implementation = model.deployImplementation(deployer_, owner_);
        proxy = model.deployProxy(deployer_, implementation, owner_, initialValue);

        assertEq(IMockImplementation(proxy).owner(), owner_, "Initial owner should be set");
        assertEq(IMockImplementation(proxy).value(), initialValue, "Initial value should be set");
    }

    function _stemProxy(
        IOwnershipModel model,
        address proxy_,
        address proxyOwner_,
        address stemOwner_,
        address stemImplementation_
    ) internal {
        model.upgrade(proxyOwner_, proxy_, stemImplementation_);

        vm.expectRevert(
            abi.encodeWithSelector(Stem.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        IMockImplementation(proxy_).value(); // This should revert
        vm.expectRevert(
            abi.encodeWithSelector(Stem.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        IMockImplementation(proxy_).setValue(3); // This should revert
        assertEq(IMockImplementation(proxy_).owner(), stemOwner_, "Stem ownership should transfer to new owner");
    }

    // note that you cannnot unstem to a new implementation with a different owner
    // this is a funcamental limitation of the ERC1967 proxy pattern because it changes the
    // implementation address and calls the upgrade function under the same owner.
    // If the ownership is different between the old and new implementations, then this cannot
    // happen. So the upgrade has to be called later, under the new ownership.
    function _unstemProxy(
        IOwnershipModel model,
        address proxy_,
        address stemOwner,
        address proxyOwner_,
        address newImplementation,
        uint256 newValue
    ) internal {
        model.upgrade(stemOwner, proxy_, newImplementation);

        assertEq(IMockImplementation(proxy_).owner(), proxyOwner_, "_unstemProxy: Initial owner should be reset");
        assertEq(IMockImplementation(proxy_).value(), newValue, "_unstemProxy: Initial value should be reset");

        vm.expectPartialRevert(model.unauthorizedSelector());
        IMockImplementation(proxy_).setValue(newValue + 1);

        // owner is truly re-instated
        vm.prank(proxyOwner_);
        IMockImplementation(proxy_).setValue(newValue + 2);
        assertEq(
            IMockImplementation(proxy_).value(),
            newValue + 2,
            "_unstemProxy: Initial value should be changeable by owner"
        );

        // reset the values to what they were before the above test
        vm.prank(proxyOwner_);
        IMockImplementation(proxy_).setValue(newValue);
        assertEq(
            IMockImplementation(proxy_).value(),
            newValue,
            "_unstemProxy: Initial value should be resetable by owner"
        );
    }

    function _upgradeProxy(
        IOwnershipModel source,
        IOwnershipModel target,
        address proxy_,
        address sourceOwner,
        address targetOwner,
        address targetImplementation,
        uint256 sourceValue,
        bool changeValue,
        uint256 targetValue
    ) internal {
        assertEq(IMockImplementation(proxy_).value(), sourceValue, "_upgradeProxy: Initial value should be known");
        // 8. Unstem the contract (i.e put the same one back) with no changes
        if (changeValue) {
            assertEq(
                sourceOwner,
                targetOwner,
                "_upgradeProxy: cannot upgrade state at the same time as an ownership change"
            );
            assertEq(
                IMockImplementation(proxy_).owner(),
                sourceOwner,
                "_upgradeProxy: from owner should be set correctly"
            );
            source.upgrade(sourceOwner, proxy_, targetImplementation, targetValue);
        } else {
            source.upgrade(sourceOwner, proxy_, targetImplementation);
        }
        assertEq(IMockImplementation(proxy_).owner(), targetOwner, "_upgradeProxy: Initial owner should be reset");
        assertEq(
            IMockImplementation(proxy_).value(),
            changeValue ? targetValue : sourceValue,
            "Initial value should be reset"
        );

        vm.expectPartialRevert(target.unauthorizedSelector());
        IMockImplementation(proxy_).setValue(sourceValue + targetValue + 1);

        // owner is truly re-instated
        vm.prank(targetOwner);
        IMockImplementation(proxy_).setValue(sourceValue + targetValue + 2);
        assertEq(
            IMockImplementation(proxy_).value(),
            sourceValue + targetValue + 2,
            "_upgradeProxy: Initial value should be changeable by owner"
        );

        // reset the value
        vm.prank(targetOwner);
        IMockImplementation(proxy_).setValue(changeValue ? targetValue : sourceValue);
        assertEq(
            IMockImplementation(proxy_).value(),
            changeValue ? targetValue : sourceValue,
            "_upgradeProxy: Initial value should be resetable by owner"
        );
    }

    /**
     * @dev Test stemming behavior with all models
     */
    function testStemmingBehaviorWithAllModels() public {
        for (uint i = 0; i < models.length; i++) {
            vm.revertToState(baseSnapshot);
            console2.log("Testing stemming behavior with", getModelName(i));

            IOwnershipModel model = createAdapter(i);
            (address proxy, address implementation) = _deploy(model, deployer, proxyOwner, INITIAL_VALUE);

            _stemProxy(model, proxy, proxyOwner, emergencyOwner, address(stemImplementation));

            _unstemProxy(
                model,
                proxy,
                emergencyOwner,
                proxyOwner,
                implementation, // back to the original
                INITIAL_VALUE
            );
        }
    }

    /**
     * @dev Test all ownership transitions systematically (n^2 combinations)
     * Use proper snapshot management to avoid gas issues
     */
    function testAllOwnershipTransitions() public {
        vm.skip(true); // this needs specific adapters to manage ownership transition between models
        for (uint i = 0; i < models.length; i++) {
            for (uint j = 0; j < models.length; j++) {
                if (i == 2 || j == 2) {
                    continue; // Skip the last model (OZOwnable) for now
                }
                vm.revertToState(baseSnapshot); // Correct revert function
                console2.log("Testing transition from", getModelName(i), "to", getModelName(j));
                _testOwnershipTransition(createAdapter(i), createAdapter(j));
            }
        }
    }

    /**
     * @dev Test a specific ownership transition
     */
    function _testOwnershipTransition(IOwnershipModel source, IOwnershipModel target) internal {
        (address proxy, address sourceImplementation) = _deploy(source, deployer, proxyOwner, INITIAL_VALUE);

        // _stemProxy(source, proxy, proxyOwner, emergencyOwner, address(stemImplementation));

        // _unstemProxy(
        //     source,
        //     proxy,
        //     emergencyOwner,
        //     proxyOwner,
        //     sourceImplementation, // back to the original
        //     INITIAL_VALUE
        // );

        address targetImplementation = target.deployImplementation(deployer, proxyOwner);

        _upgradeProxy(
            source,
            target,
            proxy,
            proxyOwner,
            proxyOwner, // cannot change the owner and the value at the same time
            targetImplementation,
            INITIAL_VALUE,
            true, // change the value
            INITIAL_VALUE + 100
        );
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
