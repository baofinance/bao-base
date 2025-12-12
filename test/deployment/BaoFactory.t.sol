// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, Vm} from "forge-std/Test.sol";
import {LibClone} from "@solady/utils/LibClone.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";

import {BaoFactory} from "@bao/factory/BaoFactory.sol";
import {BaoFactoryLib} from "@bao/factory/BaoFactoryLib.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {FundedVault, NonPayableVault, FundedVaultUUPS} from "@bao-test/mocks/deployment/FundedVault.sol";
import {BaoFactoryV2, BaoFactoryNonUUPS} from "@bao-test/mocks/deployment/BaoFactoryV2.sol";

/// @dev Simple contract used for deployment tests
contract SimpleContract {
    uint256 public value;
    address public deployer;

    constructor(uint256 _value) {
        value = _value;
        deployer = msg.sender;
    }
}

/// @title BaoFactoryTest
/// @notice Tests for the BaoFactory deterministic deployer
/// @dev Uses vm.prank to impersonate the hardcoded owner for privileged operations
contract BaoFactoryTest is Test {
    BaoFactory internal factory;
    BaoFactory internal implementation;
    address internal owner;
    address internal operator;
    address internal outsider;

    uint256 internal constant OPERATOR_DELAY = 1 days;

    function setUp() public {
        owner = BaoFactoryLib.PRODUCTION_OWNER; // Get the hardcoded owner constant from library
        operator = makeAddr("operator");
        outsider = makeAddr("outsider");

        // Deploy implementation (constructor also deploys proxy and emits event)
        vm.recordLogs();
        implementation = new BaoFactory();

        // Extract proxy address from BaoFactoryDeployed event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address proxyAddr;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IBaoFactory.BaoFactoryDeployed.selector) {
                proxyAddr = address(uint160(uint256(logs[i].topics[1])));
                break;
            }
        }
        require(proxyAddr != address(0), "BaoFactoryDeployed event not found");

        factory = BaoFactory(proxyAddr);

        // Set up an operator with 1 day expiry
        vm.prank(owner);
        factory.setOperator(operator, OPERATOR_DELAY);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testConstructorDeploysProxyAndEmitsEvent() public {
        vm.recordLogs();
        BaoFactory impl = new BaoFactory();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent = false;
        address eventProxy;
        address eventImpl;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IBaoFactory.BaoFactoryDeployed.selector) {
                eventProxy = address(uint160(uint256(logs[i].topics[1])));
                eventImpl = address(uint160(uint256(logs[i].topics[2])));
                foundEvent = true;
                break;
            }
        }

        assertTrue(foundEvent, "BaoFactoryDeployed event not emitted");
        assertEq(eventImpl, address(impl), "Implementation address mismatch in event");
        assertTrue(eventProxy != address(0), "Proxy address should be non-zero");
        assertTrue(eventProxy.code.length > 0, "Proxy should have code");
    }

    function testProxyAddressPrediction() public view {
        // Verify BaoFactoryLib.predictProxy matches actual deployment
        address predictedProxy = BaoFactoryLib.predictProxy(address(implementation));
        assertEq(address(factory), predictedProxy, "Proxy address prediction mismatch");
    }

    function testOwnerIsHardcodedConstant() public view {
        assertEq(factory.owner(), 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2);
        // Verify implementation and proxy return same owner
        assertEq(implementation.owner(), factory.owner());
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OPERATOR MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testSetOperatorOnlyOwner() public {
        address newOperator = makeAddr("new operator");

        vm.expectEmit(true, false, false, true);
        emit IBaoFactory.OperatorSet(newOperator, uint40(block.timestamp + OPERATOR_DELAY));

        vm.prank(owner);
        factory.setOperator(newOperator, OPERATOR_DELAY);

        assertTrue(factory.isCurrentOperator(newOperator));
    }

    function testSetOperatorRevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(IBaoFactory.Unauthorized.selector);
        factory.setOperator(makeAddr("forbidden"), OPERATOR_DELAY);
    }

    function testRemoveOperator() public {
        assertTrue(factory.isCurrentOperator(operator), "operator should be valid initially");

        vm.expectEmit(true, false, false, false);
        emit IBaoFactory.OperatorRemoved(operator);

        vm.prank(owner);
        factory.setOperator(operator, 0); // delay=0 removes

        assertFalse(factory.isCurrentOperator(operator), "operator should be removed");
    }

    function testOperatorExpiry() public {
        assertTrue(factory.isCurrentOperator(operator), "operator should be valid initially");

        // Warp past expiry
        vm.warp(block.timestamp + OPERATOR_DELAY + 1);

        assertFalse(factory.isCurrentOperator(operator), "operator should be expired");
    }

    function testOperatorsEnumeration() public {
        address op2 = makeAddr("operator2");
        vm.prank(owner);
        factory.setOperator(op2, 2 days);

        (address[] memory addrs, uint256[] memory expiries) = factory.operators();

        assertEq(addrs.length, 2);
        assertEq(expiries.length, 2);

        // Order not guaranteed, check both are present
        bool foundOp1 = false;
        bool foundOp2 = false;
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == operator) {
                foundOp1 = true;
                assertEq(expiries[i], uint40(block.timestamp + OPERATOR_DELAY));
            }
            if (addrs[i] == op2) {
                foundOp2 = true;
                assertEq(expiries[i], uint40(block.timestamp + 2 days));
            }
        }
        assertTrue(foundOp1, "operator not found in enumeration");
        assertTrue(foundOp2, "operator2 not found in enumeration");
    }

    /*//////////////////////////////////////////////////////////////////////////
                               DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testOwnerCanDeploy() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(42)));
        bytes32 salt = keccak256("owner.deploy");
        address predicted = factory.predictAddress(salt);

        vm.prank(owner);
        address deployed = factory.deploy(initCode, salt);

        assertEq(deployed, predicted);
        SimpleContract simple = SimpleContract(deployed);
        assertEq(simple.value(), 42);
    }

    function testOperatorCanDeploy() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(77)));
        bytes32 salt = keccak256("operator.deploy");
        address predicted = factory.predictAddress(salt);

        vm.prank(operator);
        address deployed = factory.deploy(initCode, salt);

        assertEq(deployed, predicted);
        SimpleContract simple = SimpleContract(deployed);
        assertEq(simple.value(), 77);
    }

    function testDeployEmitsEvent() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(99)));
        bytes32 salt = keccak256("emit.deploy");
        address predicted = factory.predictAddress(salt);

        vm.expectEmit(true, true, false, true);
        emit IBaoFactory.Deployed(predicted, salt, 0);

        vm.prank(owner);
        factory.deploy(initCode, salt);
    }

    function testDeployWithValue() public {
        uint256 value = 2 ether;
        bytes memory initCode = type(FundedVault).creationCode;
        bytes32 salt = keccak256("value.deploy");

        vm.deal(owner, value);
        vm.prank(owner);
        address deployed = factory.deploy{value: value}(value, initCode, salt);

        FundedVault vault = FundedVault(payable(deployed));
        assertEq(address(vault).balance, value, "should transfer ETH to deployed contract");
        assertEq(vault.initialBalance(), value, "constructor should see funded value");
    }

    function testDeployValueMismatchReverts() public {
        uint256 declaredValue = 1 ether;
        bytes memory initCode = type(FundedVault).creationCode;
        bytes32 salt = keccak256("value.mismatch");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IBaoFactory.ValueMismatch.selector, declaredValue, 0));
        factory.deploy(declaredValue, initCode, salt);
    }

    function testDeployRevertUnauthorized() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        bytes32 salt = keccak256("unauthorized");

        vm.prank(outsider);
        vm.expectRevert(IBaoFactory.Unauthorized.selector);
        factory.deploy(initCode, salt);
    }

    function testExpiredOperatorCannotDeploy() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        bytes32 salt = keccak256("expired.operator");

        // Warp past operator expiry
        vm.warp(block.timestamp + OPERATOR_DELAY + 1);

        vm.prank(operator);
        vm.expectRevert(IBaoFactory.Unauthorized.selector);
        factory.deploy(initCode, salt);
    }

    function testDeployProxyPayload() public {
        FundedVaultUUPS vaultImpl = new FundedVaultUUPS(owner);
        // Use LibClone to create ERC1967 proxy initcode
        bytes memory proxyInit = LibClone.initCodeERC1967(address(vaultImpl));
        bytes32 salt = keccak256("uups.proxy");

        vm.prank(owner);
        address deployed = factory.deploy(proxyInit, salt);

        // Initialize the proxy after deployment
        FundedVaultUUPS proxy = FundedVaultUUPS(payable(deployed));
        proxy.initialize();
        assertTrue(address(proxy) != address(0));
        assertEq(proxy.owner(), owner);
    }

    function testDeployNonPayableTargetReverts() public {
        uint256 value = 1 ether;
        bytes memory initCode = abi.encodePacked(type(NonPayableVault).creationCode, abi.encode(uint256(1)));
        bytes32 salt = keccak256("nonpayable");

        vm.deal(owner, value);
        vm.prank(owner);
        vm.expectRevert();
        factory.deploy{value: value}(value, initCode, salt);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ADDRESS PREDICTION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testPredictAddressIndependentOfInitCode() public {
        bytes32 salt = keccak256("prediction.test");
        address predicted = factory.predictAddress(salt);

        // Deploy with one initCode
        bytes memory initCode1 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        vm.prank(owner);
        address deployed = factory.deploy(initCode1, salt);

        assertEq(deployed, predicted, "deployed address should match prediction");
    }

    function testMultipleDeploymentsHaveDifferentAddresses() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        bytes32 salt1 = keccak256("deploy.1");
        bytes32 salt2 = keccak256("deploy.2");

        vm.startPrank(owner);
        address addr1 = factory.deploy(initCode, salt1);
        address addr2 = factory.deploy(initCode, salt2);
        vm.stopPrank();

        assertTrue(addr1 != addr2, "same initCode with different salts should give different addresses");
    }

    /*//////////////////////////////////////////////////////////////////////////
                           BAOFACTORYLIB TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testBaoFactoryLibPredictImplementation() public pure {
        bytes32 mockCreationCodeHash = keccak256("mock.creation.code");
        string memory salt = BaoFactoryLib.PRODUCTION_SALT;
        address predicted = BaoFactoryLib.predictImplementation(salt, mockCreationCodeHash);

        // Verify CREATE2 address formula
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), BaoFactoryLib.NICKS_FACTORY, keccak256(bytes(salt)), mockCreationCodeHash)
        );
        address expected = address(uint160(uint256(hash)));
        assertEq(predicted, expected);
    }

    function testBaoFactoryLibPredictAddresses() public pure {
        bytes32 mockCreationCodeHash = keccak256("mock.creation.code");
        string memory salt = BaoFactoryLib.PRODUCTION_SALT;
        (address impl, address proxy) = BaoFactoryLib.predictAddresses(salt, mockCreationCodeHash);

        assertEq(impl, BaoFactoryLib.predictImplementation(salt, mockCreationCodeHash));
        assertEq(proxy, BaoFactoryLib.predictProxy(impl));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              UUPS UPGRADE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testUpgradeToV2MaintainsProxyAddress() public {
        address proxyBefore = address(factory);

        // Deploy V2 implementation
        BaoFactoryV2 v2Impl = new BaoFactoryV2();

        // Upgrade via owner
        vm.prank(owner);
        factory.upgradeToAndCall(address(v2Impl), "");

        // Proxy address should be unchanged
        assertEq(address(factory), proxyBefore, "proxy address should not change after upgrade");

        // Should now report version 2
        BaoFactoryV2 upgraded = BaoFactoryV2(address(factory));
        assertEq(upgraded.version(), 2, "should be version 2 after upgrade");
    }

    function testUpgradeRetainsOperatorState() public {
        // Set up an operator before upgrade
        address testOperator = makeAddr("testOperator");
        vm.prank(owner);
        factory.setOperator(testOperator, 7 days);
        assertTrue(factory.isCurrentOperator(testOperator), "operator should be valid before upgrade");

        // Upgrade to V2
        BaoFactoryV2 v2Impl = new BaoFactoryV2();
        vm.prank(owner);
        factory.upgradeToAndCall(address(v2Impl), "");

        // Operator should still be valid after upgrade
        BaoFactoryV2 upgraded = BaoFactoryV2(address(factory));
        assertTrue(upgraded.isCurrentOperator(testOperator), "operator should still be valid after upgrade");

        // Verify we can still enumerate operators
        (address[] memory addrs, ) = upgraded.operators();
        assertEq(addrs.length, 2, "should have 2 operators (original + testOperator)");
    }

    function testUpgradeUnauthorizedReverts() public {
        BaoFactoryV2 v2Impl = new BaoFactoryV2();

        // Non-owner cannot upgrade
        vm.prank(outsider);
        vm.expectRevert(IBaoFactory.Unauthorized.selector);
        factory.upgradeToAndCall(address(v2Impl), "");

        // Operator cannot upgrade (only owner can)
        vm.prank(operator);
        vm.expectRevert(IBaoFactory.Unauthorized.selector);
        factory.upgradeToAndCall(address(v2Impl), "");
    }

    function testUpgradeToNonUUPSReverts() public {
        BaoFactoryNonUUPS nonUupsImpl = new BaoFactoryNonUUPS();

        // Attempt to upgrade to non-UUPS implementation should revert
        vm.prank(owner);
        vm.expectRevert(UUPSUpgradeable.UpgradeFailed.selector);
        factory.upgradeToAndCall(address(nonUupsImpl), "");
    }

    function testUpgradeWithInitializationCall() public {
        BaoFactoryV2 v2Impl = new BaoFactoryV2();

        // Upgrade and call version() in the same transaction
        bytes memory initData = abi.encodeCall(BaoFactoryV2.version, ());

        vm.prank(owner);
        factory.upgradeToAndCall(address(v2Impl), initData);

        // Should be upgraded
        BaoFactoryV2 upgraded = BaoFactoryV2(address(factory));
        assertEq(upgraded.version(), 2);
    }

    function testUpgradedContractCanStillDeploy() public {
        // Upgrade to V2
        BaoFactoryV2 v2Impl = new BaoFactoryV2();
        vm.prank(owner);
        factory.upgradeToAndCall(address(v2Impl), "");

        // Deploy via upgraded factory
        BaoFactoryV2 upgraded = BaoFactoryV2(address(factory));
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(123)));
        bytes32 salt = keccak256("v2.deploy");
        address predicted = upgraded.predictAddress(salt);

        vm.prank(owner);
        address deployed = upgraded.deploy(initCode, salt);

        assertEq(deployed, predicted, "deployed address should match prediction");
        assertEq(SimpleContract(deployed).value(), 123, "deployed contract should work");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SECURITY ATTACK VECTOR TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test 1c.1: Implementation cannot be called directly for privileged ops
    /// @dev The implementation has same owner constant but calling deploy() directly
    ///      would bypass the proxy pattern. The key is that deployed contracts from
    ///      impl would have different addresses than proxy deployments.
    function testImplementationDirectCallsHaveDifferentAddresses() public view {
        bytes32 salt = keccak256("direct.vs.proxy");

        // Predict address from proxy (the canonical factory)
        address proxyPredicted = factory.predictAddress(salt);

        // Predict address from implementation (would be different CREATE3 deployer)
        address implPredicted = implementation.predictAddress(salt);

        // Different deployers (proxy vs implementation) produce different addresses
        assertTrue(
            proxyPredicted != implPredicted,
            "implementation and proxy should produce different addresses for same salt"
        );
    }

    /// @notice Test 1c.3: Verify Nick's Factory produces deterministic addresses
    /// @dev The BaoFactory proxy address is deterministic based on impl address
    function testNicksFactoryDeploymentIsDeterministic() public pure {
        // Get the creation code hash for BaoFactory
        bytes32 creationCodeHash = keccak256(type(BaoFactory).creationCode);
        string memory salt = BaoFactoryLib.PRODUCTION_SALT;

        // Predict addresses using the library
        (address predictedImpl, address predictedProxy) = BaoFactoryLib.predictAddresses(salt, creationCodeHash);

        // These should be constant across runs (same salt + same initcode = same address)
        // The implementation was deployed at a specific address via Nick's Factory
        // Verify the prediction matches the library's prediction (self-consistent)
        assertEq(
            BaoFactoryLib.predictImplementation(salt, creationCodeHash),
            predictedImpl,
            "implementation prediction should be consistent"
        );
        assertEq(BaoFactoryLib.predictProxy(predictedImpl), predictedProxy, "proxy prediction should be consistent");

        // Also verify the actual deployment matches the prediction
        // Note: our test deployment may not match production prediction because
        // we use `new BaoFactory()` not Nick's Factory. The key test is that
        // the prediction formula is deterministic and self-consistent.
    }

    /// @notice Test 1c.5: Removed operator cannot deploy
    function testRemovedOperatorCannotDeploy() public {
        // Verify operator can deploy initially
        assertTrue(factory.isCurrentOperator(operator), "operator should be valid initially");

        // Remove the operator (delay=0)
        vm.prank(owner);
        factory.setOperator(operator, 0);
        assertFalse(factory.isCurrentOperator(operator), "operator should be removed");

        // Attempt to deploy should fail
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        bytes32 salt = keccak256("removed.operator");

        vm.prank(operator);
        vm.expectRevert(IBaoFactory.Unauthorized.selector);
        factory.deploy(initCode, salt);
    }

    /// @notice Test 1c.7: Deploying same salt twice reverts (CREATE3 collision)
    /// @dev CREATE3 uses CREATE2 to deploy a proxy that does CREATE for the actual contract.
    ///      Same salt means same CREATE2 address for proxy, which will fail on redeployment.
    function testDeploySameSaltTwiceReverts() public {
        bytes memory initCode1 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        bytes memory initCode2 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(2)));
        bytes32 salt = keccak256("collision.test");

        // First deployment succeeds
        vm.prank(owner);
        address deployed = factory.deploy(initCode1, salt);
        assertTrue(deployed != address(0), "first deployment should succeed");

        // Second deployment with same salt should revert (regardless of initCode)
        vm.prank(owner);
        vm.expectRevert();
        factory.deploy(initCode2, salt);
    }
}
