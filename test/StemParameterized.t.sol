// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stem} from "src/Stem.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Import all ownership model implementations
import {MockImplementationWithState} from "mocks/MockImplementationWithState.sol"; // BaoOwnable
import {MockImplementationWithState_v2} from "mocks/MockImplementationWithState_v2.sol"; // BaoOwnable_v2
import {MockImplementationOwnableUpgradeable} from "mocks/MockImplementationOwnableUpgradeable.sol"; // OZ Ownable

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
    Stem public stemImplementation;
    address public proxyOwner;
    address public user;
    address public emergencyOwner;

    // Constants for test values
    uint256 constant INITIAL_VALUE = 100;
    uint256 constant UPDATED_VALUE = 200;
    uint256 constant STEM_TRANSFER_DELAY = 100;
    uint256 constant TRANSFER_DELAY = 3600; // BaoOwnable_v2 delay (1 hour)

    // Base snapshot for test isolation
    uint256 private baseSnapshot;

    function setUp() public {
        // Create test wallets
        proxyOwner = vm.createWallet("proxyOwner").addr;
        user = vm.createWallet("user").addr;
        emergencyOwner = vm.createWallet("emergencyOwner").addr;

        // Deploy the Stem implementation with emergency owner and delay
        stemImplementation = new Stem(emergencyOwner, STEM_TRANSFER_DELAY);

        // Initialize models array
        models[0] = OwnershipModel.BaoOwnable;
        models[1] = OwnershipModel.BaoOwnable_v2;
        models[2] = OwnershipModel.OZOwnable;

        // Store base snapshot for all tests to revert to
        baseSnapshot = vm.snapshotState();
    }

    /**
     * @dev Deploy appropriate implementation based on the ownership model
     */
    function deployImplementation(OwnershipModel model, address owner) internal returns (address impl) {
        if (model == OwnershipModel.BaoOwnable) {
            impl = address(new MockImplementationWithState());
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            impl = address(new MockImplementationWithState_v2(owner));
        } else if (model == OwnershipModel.OZOwnable) {
            impl = address(new MockImplementationOwnableUpgradeable());
        }
    }

    /**
     * @dev Setup ownership to proxyOwner
     */
    function setupOwnership(address proxy, OwnershipModel model, address owner) internal {
        if (model == OwnershipModel.BaoOwnable) {
            // For BaoOwnable, need to transfer from test contract to proxyOwner
            MockImplementationWithState(proxy).transferOwnership(owner);
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            // For BaoOwnable_v2, owner is already set in constructor (see deployImplementation), but needs a time delay
            skip(TRANSFER_DELAY);
        } else if (model == OwnershipModel.OZOwnable) {
            // For OZOwnable, owner is set in initialize
        } else {
            revert("Invalid ownership model");
        }
    }

    /**
     * @dev Generate initialization data based on ownership model
     */
    function getInitData(OwnershipModel model, address owner) internal pure returns (bytes memory) {
        if (model == OwnershipModel.BaoOwnable) {
            return abi.encodeWithSelector(MockImplementationWithState.initialize.selector, owner, INITIAL_VALUE);
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            return abi.encodeWithSelector(MockImplementationWithState_v2.initialize.selector, INITIAL_VALUE);
        } else if (model == OwnershipModel.OZOwnable) {
            return
                abi.encodeWithSelector(MockImplementationOwnableUpgradeable.initialize.selector, owner, INITIAL_VALUE);
        } else {
            revert("Invalid ownership model");
        }
    }

    function getUpgradeData(OwnershipModel model) internal pure returns (bytes memory) {
        if (model == OwnershipModel.BaoOwnable) {
            return abi.encodeWithSelector(MockImplementationWithState.postUpgradeSetup.selector, UPDATED_VALUE);
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            return abi.encodeWithSelector(MockImplementationWithState_v2.postUpgradeSetup.selector, UPDATED_VALUE);
        } else if (model == OwnershipModel.OZOwnable) {
            return
                abi.encodeWithSelector(MockImplementationOwnableUpgradeable.postUpgradeSetup.selector, UPDATED_VALUE);
        } else {
            revert("Invalid ownership model");
        }
    }

    /**
     * @dev Get the value from any implementation
     */
    function getValue(address proxy, OwnershipModel model) internal view returns (uint256) {
        if (model == OwnershipModel.BaoOwnable) {
            return MockImplementationWithState(proxy).value();
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            return MockImplementationWithState_v2(proxy).value();
        } else if (model == OwnershipModel.OZOwnable) {
            return MockImplementationOwnableUpgradeable(proxy).value();
        } else {
            revert("Invalid ownership model");
        }
    }

    /**
     * @dev Get the owner from any implementation
     */
    function getOwner(address proxy, OwnershipModel model) internal view returns (address) {
        if (model == OwnershipModel.BaoOwnable) {
            return MockImplementationWithState(proxy).owner();
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            return MockImplementationWithState_v2(proxy).owner();
        } else if (model == OwnershipModel.OZOwnable) {
            return MockImplementationOwnableUpgradeable(proxy).owner();
        } else {
            revert("Invalid ownership model");
        }
    }

    /**
     * @dev Get model name as string (for console output)
     */
    function getModelName(OwnershipModel model) internal pure returns (string memory) {
        if (model == OwnershipModel.BaoOwnable) {
            return "BaoOwnable";
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            return "BaoOwnable_v2";
        } else if (model == OwnershipModel.OZOwnable) {
            return "OZOwnable";
        } else {
            return "Invalid";
        }
    }

    /**
     * @dev Test all ownership transitions systematically (n^2 combinations)
     * Use proper snapshot management to avoid gas issues
     */
    function testAllOwnershipTransitions() public {
        for (uint i = 0; i < models.length; i++) {
            for (uint j = 0; j < models.length; j++) {
                vm.revertToState(baseSnapshot); // Correct revert function
                console.log("Testing transition from", getModelName(models[i]), "to", getModelName(models[j]));
                _testOwnershipTransition(models[i], models[j]);
            }
        }
    }

    /**
     * @dev Test a specific ownership transition
     */
    function _testOwnershipTransition(OwnershipModel source, OwnershipModel target) internal {
        // 1. Setup source contract
        address impl = deployImplementation(source, proxyOwner);
        bytes memory initData = getInitData(source, proxyOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

        // 2. Handle initial ownership setup
        setupOwnership(address(proxy), source, proxyOwner);

        // 3. Verify initial state
        assertEq(getValue(address(proxy), source), INITIAL_VALUE, "Initial value should be set");
        assertEq(getOwner(address(proxy), source), proxyOwner, "Initial owner should be set for BaoOwnable");

        // 4. Upgrade to Stem
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();
        setupOwnership(address(proxy), source, proxyOwner);

        // 6. Upgrade from Stem to target implementation
        address targetImpl = deployImplementation(target, proxyOwner);
        bytes memory upgradeData = getUpgradeData(target);

        vm.startPrank(emergencyOwner); // Emergency owner is now the owner
        UnsafeUpgrades.upgradeProxy(address(proxy), targetImpl, upgradeData);
        vm.stopPrank();

        // 7. Verify final state
        assertEq(getValue(address(proxy), target), UPDATED_VALUE, "Updated value should be set");

        if (target == OwnershipModel.BaoOwnable) {
            assertEq(getOwner(address(proxy), target), address(this), "Owner should be test contract for BaoOwnable");
            MockImplementationWithState(address(proxy)).transferOwnership(emergencyOwner);
            assertEq(getOwner(address(proxy), target), emergencyOwner, "Owner should transfer to emergency owner");
        } else if (target == OwnershipModel.BaoOwnable_v2) {
            assertEq(
                getOwner(address(proxy), target),
                address(this),
                "Owner should be test contract for BaoOwnable_v2"
            );
        } else if (target == OwnershipModel.OZOwnable) {
            assertEq(getOwner(address(proxy), target), emergencyOwner, "Owner should be emergency owner for OZOwnable");
        }
    }

    /**
     * @dev Test stemming behavior with all models
     */
    function testStemmingBehaviorWithAllModels() public {
        for (uint i = 0; i < models.length; i++) {
            vm.revertToState(baseSnapshot);
            console.log("Testing stemming behavior with", getModelName(models[i]));
            testStemmingBehavior(models[i]);
        }
    }

    /**
     * @dev Test stemming behavior with a specific model
     */
    function testStemmingBehavior(OwnershipModel model) internal {
        // 1. Setup contract based on model
        address impl = deployImplementation(model, proxyOwner);
        bytes memory initData = getInitData(model, proxyOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

        // 2. Handle ownership setup
        setupOwnership(address(proxy), model, proxyOwner);

        // 3. Verify initial state
        uint256 initialValue = getValue(address(proxy), model);
        assertEq(initialValue, INITIAL_VALUE, "Initial value should be set");

        // 4. Stem the contract
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 5. Test that functions are stemmed
        vm.expectRevert(); // Should revert with a function not found error
        getValue(address(proxy), model); // This should revert

        // 6. Wait for ownership transfer
        if (model == OwnershipModel.BaoOwnable || model == OwnershipModel.BaoOwnable_v2) {
            skip(TRANSFER_DELAY);
        }

        // 7. Verify Stem ownership
        assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Stem ownership should transfer to emergency owner");

        // 8. Unstem the contract
        address newImpl = deployImplementation(model, proxyOwner);
        bytes memory newInitData = getUpgradeData(model);

        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), newImpl, newInitData);
        vm.stopPrank();

        // 9. Verify contract works after unstemming
        assertEq(getValue(address(proxy), model), UPDATED_VALUE, "Value should be updated after unstemming");
    }

    /**
     * @dev Specific test for BaoOwnable_v2 automatic ownership transfer
     */
    function testBaoOwnableV2AutoTransfer() public {
        // 1. Deploy BaoOwnable_v2 implementation
        address originalOwner = vm.createWallet("originalOwner").addr;
        MockImplementationWithState_v2 implementation = new MockImplementationWithState_v2(originalOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(MockImplementationWithState_v2.initialize.selector, INITIAL_VALUE)
        );
        MockImplementationWithState_v2 proxied = MockImplementationWithState_v2(address(proxy));

        // 2. Verify initial ownership
        assertEq(proxied.owner(), address(this), "Initial owner should be test contract");
        assertEq(proxied.value(), INITIAL_VALUE, "Initial value should be set");

        // 7. Transfer ownership to original owner
        // also check the stem
        assertEq(stemImplementation.owner(), address(this), "Stem owner should still be test contract");
        skip(STEM_TRANSFER_DELAY);
        assertEq(stemImplementation.owner(), emergencyOwner, "Stem owner should now be emergencyOwner");
        skip(TRANSFER_DELAY); // skip again in case the ownable delay is longer
        assertEq(proxied.owner(), originalOwner, "Owner should be now be new original owner");

        // all good

        // 3. Stem the contract
        vm.startPrank(originalOwner); // only the original owner can now stem.
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();
        // as we waited before for the stem to transfer ownerhip before, the proxy is now immediately is owned by the emergency owner
        assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Stem ownership should transfer to emergency owner");

        // 5. Unstem with a new BaoOwnable_v2 implementation
        address newOwner = vm.createWallet("newOwner").addr;
        MockImplementationWithState_v2 newImpl = new MockImplementationWithState_v2(newOwner);

        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(
            address(proxy),
            address(newImpl),
            "" // can only do initialisation now with the deployer - that's who owns the implementation, atm!
        );
        vm.stopPrank();
        assertEq(proxied.value(), INITIAL_VALUE, "Value should be as before");
        proxied.postUpgradeSetup(UPDATED_VALUE);

        // 6. Verify new state
        assertEq(proxied.owner(), address(this), "Owner should be deployer");
        assertEq(proxied.value(), UPDATED_VALUE, "Value should be updated");

        // 7. Transfer ownership to new owner
        skip(TRANSFER_DELAY);
        assertEq(proxied.owner(), newOwner, "Owner should be new owner");
    }

    /**
     * @dev Test direct transitions between ownership models without Stem
     */
    function testDirectOwnershipTransitions() public {
        // Test each source → target direct transition
        for (uint i = 0; i < models.length; i++) {
            for (uint j = 0; j < models.length; j++) {
                if (i != j) {
                    vm.revertToState(baseSnapshot);
                    console.log(
                        "Testing direct transition from",
                        getModelName(models[i]),
                        "to",
                        getModelName(models[j])
                    );
                    testDirectTransition(models[i], models[j]);
                }
            }
        }
    }

    /**
     * @dev Test direct transition between two ownership models
     */
    function testDirectTransition(OwnershipModel source, OwnershipModel target) internal {
        // 1. Setup source contract
        address impl = deployImplementation(source, proxyOwner);
        bytes memory initData = getInitData(source, proxyOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

        // 2. Handle initial ownership setup
        setupOwnership(address(proxy), source, proxyOwner);

        // 3. Verify initial state
        assertEq(getValue(address(proxy), source), INITIAL_VALUE, "Initial value should be set");

        // 4. Direct upgrade to target implementation
        address targetImpl = deployImplementation(target, proxyOwner);
        bytes memory targetInitData = getUpgradeData(target);

        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), targetImpl, targetInitData);
        vm.stopPrank();

        // 5. Verify final state
        assertEq(getValue(address(proxy), target), UPDATED_VALUE, "Updated value should be set");

        if (target == OwnershipModel.BaoOwnable) {
            assertEq(getOwner(address(proxy), target), address(this), "Owner should be test contract for BaoOwnable");
        } else if (target == OwnershipModel.BaoOwnable_v2) {
            assertEq(
                getOwner(address(proxy), target),
                address(this),
                "Owner should be test contract for BaoOwnable_v2"
            );
        } else if (target == OwnershipModel.OZOwnable) {
            assertEq(getOwner(address(proxy), target), proxyOwner, "Owner should be proxyOwner for OZOwnable");
        }
    }

    /**
     * @dev Test all functions remain blocked when stemmed for all ownership models
     */
    function testAllFunctionsStemmed() public {
        for (uint i = 0; i < models.length; i++) {
            console.log("Testing stemming behavior with", getModelName(models[i]));
            baseSnapshot = vm.snapshotState();
            testAllFunctionsStemmedForModel(models[i]);
            vm.revertToState(baseSnapshot);
        }
    }

    /**
     * @dev Test that all functions of a specific model are properly stemmed
     */
    function testAllFunctionsStemmedForModel(OwnershipModel model) internal {
        // 1. Setup contract based on model
        address impl = deployImplementation(model, proxyOwner);
        bytes memory initData = getInitData(model, proxyOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

        // 2. Setup ownership using the helper function that handles different models
        setupOwnership(address(proxy), model, proxyOwner);

        // 3. Stem the contract - use startPrank/stopPrank instead of just prank
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 4. Test read functions are stemmed
        vm.expectRevert();
        getValue(address(proxy), model);

        // 5. Test write functions are stemmed
        // For BaoOwnable and BaoOwnable_v2
        if (model == OwnershipModel.BaoOwnable) {
            vm.prank(proxyOwner);
            vm.expectRevert();
            MockImplementationWithState(address(proxy)).setValue(999);

            vm.prank(proxyOwner);
            vm.expectRevert();
            MockImplementationWithState(address(proxy)).incrementValue();
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            vm.prank(proxyOwner);
            vm.expectRevert();
            MockImplementationWithState_v2(address(proxy)).setValue(999);

            vm.prank(proxyOwner);
            vm.expectRevert();
            MockImplementationWithState_v2(address(proxy)).incrementValue();
        } else if (model == OwnershipModel.OZOwnable) {
            vm.prank(proxyOwner);
            vm.expectRevert();
            MockImplementationOwnableUpgradeable(address(proxy)).setValue(999);
        }

        // 6. Verify Stem ownership is working correctly
        assertEq(Stem(address(proxy)).owner(), address(this), "Stem owner should be the test contract");

        // 7. Wait for ownership transfer based on model
        if (model == OwnershipModel.BaoOwnable || model == OwnershipModel.BaoOwnable_v2) {
            skip(STEM_TRANSFER_DELAY);
            assertEq(Stem(address(proxy)).owner(), emergencyOwner, "Stem ownership should transfer to emergency owner");
        }
    }

    /**
     * @dev Call postUpgradeSetup for any implementation
     */
    function callPostUpgradeSetup(address proxy, OwnershipModel model, uint256 newValue, address proxyOwner_) internal {
        vm.startPrank(proxyOwner_);
        if (model == OwnershipModel.BaoOwnable) {
            MockImplementationWithState(proxy).postUpgradeSetup(newValue);
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            MockImplementationWithState_v2(proxy).postUpgradeSetup(newValue);
        } else if (model == OwnershipModel.OZOwnable) {
            MockImplementationOwnableUpgradeable(proxy).postUpgradeSetup(newValue);
        }
        vm.stopPrank();
    }

    /**
     * @dev Test post-upgrade setup functionality across all models
     */
    function testPostUpgradeSetupWithAllModels() public {
        for (uint i = 0; i < models.length; i++) {
            vm.revertToState(baseSnapshot);
            console.log("Testing postUpgradeSetup with", getModelName(models[i]));
            testPostUpgradeSetup(models[i]);
        }
    }

    /**
     * @dev Test post-upgrade setup with a specific model
     */
    function testPostUpgradeSetup(OwnershipModel model) internal {
        // 1. Setup contract based on model
        address impl = deployImplementation(model, proxyOwner);
        bytes memory initData = getInitData(model, proxyOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

        // 2. Handle ownership setup
        setupOwnership(address(proxy), model, proxyOwner);

        // 3. Verify initial state
        assertEq(getValue(address(proxy), model), INITIAL_VALUE, "Initial value should be set");

        // 4. Stem the contract
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 5. Wait for ownership transfer if needed
        if (model == OwnershipModel.BaoOwnable || model == OwnershipModel.BaoOwnable_v2) {
            skip(TRANSFER_DELAY);
        }

        // 6. Unstem to the same model
        address newImpl = deployImplementation(model, proxyOwner);

        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), newImpl, "");
        vm.stopPrank();

        // 7. Use postUpgradeSetup to set a new value
        callPostUpgradeSetup(address(proxy), model, UPDATED_VALUE, emergencyOwner);

        // 8. Verify the value was updated
        assertEq(getValue(address(proxy), model), UPDATED_VALUE, "Value should be updated via postUpgradeSetup");
    }

    /**
     * @dev Test complex state operations similar to what was tested in testComplexStateTransfer
     */
    function testComplexStateTransferWithAllModels() public {
        for (uint i = 0; i < models.length; i++) {
            vm.revertToState(baseSnapshot);
            console.log("Testing complex state transfer with", getModelName(models[i]));
            testComplexStateTransfer(models[i]);
        }
    }

    /**
     * @dev Test complex state transfer operations
     */
    function testComplexStateTransfer(OwnershipModel model) internal {
        // 1. Setup initial contract
        address impl = deployImplementation(model, proxyOwner);
        bytes memory initData = getInitData(model, proxyOwner);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);

        // 2. Setup ownership
        setupOwnership(address(proxy), model, proxyOwner);

        // 3. Make state changes if model supports it
        if (model == OwnershipModel.BaoOwnable) {
            vm.prank(proxyOwner);
            MockImplementationWithState(address(proxy)).incrementValue();
            assertEq(getValue(address(proxy), model), INITIAL_VALUE + 1, "Value should be incremented");
        } else if (model == OwnershipModel.BaoOwnable_v2) {
            vm.prank(proxyOwner);
            MockImplementationWithState_v2(address(proxy)).incrementValue();
            assertEq(getValue(address(proxy), model), INITIAL_VALUE + 1, "Value should be incremented");
        } else {
            // For OZ model, just set a new value
            vm.prank(proxyOwner);
            MockImplementationOwnableUpgradeable(address(proxy)).setValue(INITIAL_VALUE + 1);
            assertEq(getValue(address(proxy), model), INITIAL_VALUE + 1, "Value should be updated");
        }

        // 4. Pause by upgrading to Stem
        vm.startPrank(proxyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), address(stemImplementation), "");
        vm.stopPrank();

        // 5. Wait for ownership transfer if needed
        if (model == OwnershipModel.BaoOwnable || model == OwnershipModel.BaoOwnable_v2) {
            skip(TRANSFER_DELAY);
        }

        // 6. Upgrade from Stem to same implementation type but new instance
        address newImpl = deployImplementation(model, proxyOwner);

        vm.startPrank(emergencyOwner);
        UnsafeUpgrades.upgradeProxy(address(proxy), newImpl, "");
        vm.stopPrank();

        // 7. Set up the new implementation after upgrade using postUpgradeSetup
        callPostUpgradeSetup(address(proxy), model, UPDATED_VALUE, emergencyOwner);

        // 8. Verify enhanced functionality works with expected value
        assertEq(getValue(address(proxy), model), UPDATED_VALUE, "Value should be updated after postUpgradeSetup");
    }
}
