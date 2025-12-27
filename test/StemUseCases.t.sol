// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Stem_v1} from "src/Stem_v1.sol";

// Import all ownership model implementations
import {BaoOwnableAdapter} from "test/adapters/BaoOwnableAdapter.sol"; // Adapter for BaoOwnable
import {BaoOwnable_v2Adapter} from "test/adapters/BaoOwnable_v2Adapter.sol"; // Adapter for BaoOwnable_v2
import {BaoFixedOwnableAdapter} from "test/adapters/BaoFixedOwnableAdapter.sol"; // Adapter for BaoFixedOwnable
import {OZOwnableAdapter} from "test/adapters/OZOwnableAdapter.sol"; // Adapter for OZOwnable
import {IOwnershipModel} from "test/interfaces/IOwnershipModel.sol"; // Interface for ownership models
import {IMockImplementation} from "test/interfaces/IMockImplementation.sol"; // Interface for ownership models

/**
 * @title StemUseCasesTest
 * @dev Systematic test suite for all ownership models and transitions via Stem_v1
 */
contract StemUseCasesTest is Test {
    // Test configuration
    Stem_v1 public stemImplementation; // global stem implementation

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
        deployer = makeAddr("deployer");
        proxyOwner = makeAddr("proxyOwner");
        proxyOwner2 = makeAddr("proxyOwner2");
        emergencyOwner = makeAddr("emergencyOwner");
        user = makeAddr("user");

        // Deploy the Stem_v1 implementation with emergency owner and zero delay to simplify ownership
        stemImplementation = new Stem_v1(emergencyOwner, 0);

        // Store base snapshot for all tests to revert to
        baseSnapshot = vm.snapshotState();
    }

    function createAdapter(uint modelIndex) internal returns (IOwnershipModel adapter) {
        if (modelIndex == uint(IMockImplementation.ImplementationType.MockImplementationWithState)) {
            adapter = new BaoOwnableAdapter();
        } else if (modelIndex == uint(IMockImplementation.ImplementationType.MockImplementationWithState_v2)) {
            adapter = new BaoOwnable_v2Adapter();
        } else if (modelIndex == uint(IMockImplementation.ImplementationType.MockImplementationOZOwnable)) {
            adapter = new OZOwnableAdapter();
        } else if (modelIndex == uint(IMockImplementation.ImplementationType.MockImplementationBaoFixedOwnable)) {
            adapter = new BaoFixedOwnableAdapter();
        } else {
            revert("Invalid ownership model");
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
            abi.encodeWithSelector(Stem_v1.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        IMockImplementation(proxy_).value(); // This should revert
        vm.expectRevert(
            abi.encodeWithSelector(Stem_v1.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        IMockImplementation(proxy_).setValue(3); // This should revert
        assertEq(IMockImplementation(proxy_).owner(), stemOwner_, "Stem_v1 ownership should transfer to new owner");
    }

    // note that you cannot unstem to a new implementation with a different owner
    // this is a fundamental limitation of the ERC1967 proxy pattern because it changes the
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
        address targetImplementation
    ) internal {
        // console2.log("Upgrading proxy without changing value");

        assertEq(IMockImplementation(proxy_).owner(), sourceOwner, "_upgradeProxy: owners sould match");
        uint256 beforeValue = IMockImplementation(proxy_).value();
        uint256 beforeStableValue = IMockImplementation(proxy_).stableValue();
        address beforeOwner = IMockImplementation(proxy_).owner();

        source.upgrade(sourceOwner, proxy_, targetImplementation);

        assertEq(IMockImplementation(proxy_).owner(), beforeOwner, "_upgradeProxy: owner should not change");
        assertEq(IMockImplementation(proxy_).value(), beforeValue, "_upgradeProxy: Initial value should be known");
        assertEq(
            IMockImplementation(proxy_).stableValue(),
            beforeStableValue,
            "_upgradeProxy: Initial stable value should be known"
        );

        vm.expectPartialRevert(target.unauthorizedSelector());
        IMockImplementation(proxy_).setValue(beforeValue + 1);

        vm.prank(sourceOwner);
        IMockImplementation(proxy_).setValue(beforeValue + 2);
        assertEq(
            IMockImplementation(proxy_).value(),
            beforeValue + 2,
            "_upgradeProxy: Initial value should be changeable by owner"
        );
    }

    function _upgradeProxyAndChangeStuff(
        IOwnershipModel source,
        IOwnershipModel target,
        address proxy_,
        address sourceOwner,
        address targetOwner,
        address targetImplementation,
        uint256 sourceValue,
        uint256 targetValue
    ) internal {
        // console2.log("Upgrading proxy changing stuff");

        assertEq(IMockImplementation(proxy_).owner(), sourceOwner, "_upgradeProxyAndChangeStuff: owners sould match");
        assertEq(
            IMockImplementation(proxy_).value(),
            sourceValue,
            "_upgradeProxyAndChangeStuff: Initial value should be known"
        );
        uint256 beforeValue = IMockImplementation(proxy_).value();
        assertEq(beforeValue, sourceValue, "_upgradeProxyAndChangeStuff: Initial value should match source");
        uint256 beforeStableValue = IMockImplementation(proxy_).stableValue();
        address beforeOwner = IMockImplementation(proxy_).owner();
        assertEq(beforeOwner, sourceOwner, "_upgradeProxyAndChangeStuff: Initial owner should match source");

        assertTrue(beforeValue != targetValue || beforeOwner != targetOwner, "must be changing somethinhg!");
        assertEq(IMockImplementation(proxy_).implementationType(), source.implementationType());

        source.upgradeAndChangeStuff(sourceOwner, proxy_, targetImplementation, targetOwner, targetValue);
        //     -------

        assertEq(
            IMockImplementation(proxy_).implementationType(),
            target.implementationType(),
            "proxy is the target implementation type"
        );

        assertEq(IMockImplementation(proxy_).owner(), targetOwner, "_upgradeProxyAndChangeStuff: new owner is correct");
        assertEq(IMockImplementation(proxy_).value(), targetValue, "_upgradeProxyAndChangeStuff: new value is correct");
        assertEq(
            IMockImplementation(proxy_).stableValue(),
            beforeStableValue,
            "_upgradeProxyAndChangeStuff: stable value should not change"
        );

        vm.expectPartialRevert(target.unauthorizedSelector());
        IMockImplementation(proxy_).setValue(beforeValue + 1);

        vm.prank(targetOwner);
        IMockImplementation(proxy_).setValue(beforeValue + 2);
        assertEq(
            IMockImplementation(proxy_).value(),
            beforeValue + 2,
            "_upgradeProxyAndChangeStuff: Initial value should be changeable by owner"
        );
    }

    /**
     * @dev Test stemming behavior with all models
     */
    function testStemmingBehaviorWithAllModels() public {
        for (
            uint i = uint(type(IMockImplementation.ImplementationType).min);
            i <= uint(type(IMockImplementation.ImplementationType).max);
            i++
        ) {
            vm.revertToState(baseSnapshot);

            IOwnershipModel model = createAdapter(i);
            // console2.log("Testing stemming behavior with ", model.name());

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
    function testAllOwnershipModelTransitions() public {
        IOwnershipModel modelFrom;
        IOwnershipModel modelTo;
        for (
            uint i = uint(type(IMockImplementation.ImplementationType).min);
            i <= uint(type(IMockImplementation.ImplementationType).max);
            i++
        ) {
            for (
                uint j = uint(type(IMockImplementation.ImplementationType).min);
                j <= uint(type(IMockImplementation.ImplementationType).max);
                j++
            ) {
                vm.revertToState(baseSnapshot); // Correct revert function

                modelFrom = createAdapter(i);
                modelTo = createAdapter(j);
                // console2.log(">>> Testing value change in upgrade from", modelFrom.name(), "to", modelTo.name());

                _testValueChange(modelFrom, modelTo);

                vm.revertToState(baseSnapshot); // Correct revert function

                modelFrom = createAdapter(i);
                modelTo = createAdapter(j);
                // console2.log(">>> Testing owner transition in upgrade from", modelFrom.name(), "to", modelTo.name());

                _testOwnershipTransition(modelFrom, modelTo);
            }
        }
    }

    /**
     * @dev Test a specific ownership transition
     */
    function _testValueChange(IOwnershipModel source, IOwnershipModel target) internal {
        (address proxy, address sourceImplementation) = _deploy(source, deployer, proxyOwner, INITIAL_VALUE);
        uint256 sourceImplementationType = IMockImplementation(sourceImplementation).implementationType();

        assertEq(
            IMockImplementation(proxy).implementationType(),
            sourceImplementationType,
            "proxy is the source implementation type"
        );

        // create a proxy with a new owner, but same value
        _upgradeProxyAndChangeStuff(
            source,
            target,
            proxy,
            proxyOwner,
            proxyOwner,
            target.deployImplementation(deployer, proxyOwner),
            INITIAL_VALUE,
            INITIAL_VALUE + 100
        );
        assertEq(IMockImplementation(proxy).owner(), proxyOwner, "proxy owner should be the same after upgrade");
    }

    /**
     * @dev Test a specific ownership transition
     */
    function _testOwnershipTransition(IOwnershipModel source, IOwnershipModel target) internal {
        (address proxy, address sourceImplementation) = _deploy(source, deployer, proxyOwner, INITIAL_VALUE);
        uint256 sourceImplementationType = IMockImplementation(sourceImplementation).implementationType();

        assertEq(
            IMockImplementation(proxy).implementationType(),
            sourceImplementationType,
            "proxy is the source implementation type"
        );

        // create a proxy with a new owner, but same value
        _upgradeProxyAndChangeStuff(
            source,
            target,
            proxy,
            proxyOwner,
            proxyOwner2,
            target.deployImplementation(deployer, proxyOwner2),
            INITIAL_VALUE,
            INITIAL_VALUE
        );
        assertEq(IMockImplementation(proxy).owner(), proxyOwner2, "proxy owner should be changed after upgrade");
    }
}
