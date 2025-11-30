// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";

import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {MockContract} from "@bao-test/mocks/basic/MockContract.sol";
import {MockImplementation} from "@bao-test/mocks/basic/MockImplementation.sol";

// Test harness extends DeploymentJsonTesting with specific mock deployment methods
contract MyDeploymentJsonTesting is DeploymentJsonTesting {
    string constant MOCK_IMPLEMENTATION = "mockImplementation";
    string constant MOCK_IMPLEMENTATION_INIT_VALUE = "mockImplementation.initValue";

    constructor() {
        addKey(MOCK_IMPLEMENTATION);
        addUintKey(MOCK_IMPLEMENTATION_INIT_VALUE);
        // Keys used in tests
        addContract("mock1");
        addContract("mock2");
        addContract("mock3");
        addContract("existing1");
        addContract("ExistingContract");
        addContract("stETH");
        addContract("invalid");
        addContract("mock");
    }

    function deployMockContract(string memory key, string memory mockName) public returns (address) {
        MockContract mock = new MockContract(mockName);
        useExisting(key, address(mock));
        return get(key);
    }

    function deployMockImplementation(string memory key, uint256 initValue) public returns (address) {
        MockImplementation impl = new MockImplementation();
        impl.initialize(initValue);
        registerContract(
            key,
            address(impl),
            "MockImplementation",
            "test/mocks/basic/MockImplementation.sol",
            address(this)
        );
        setUint(MOCK_IMPLEMENTATION_INIT_VALUE, initValue);
        return get(key);
    }
}

/**
 * @title DeploymentBasicTest
 * @notice Tests basic deployment functionality with string keys
 */
contract DeploymentBasicTest is BaoDeploymentTest {
    MyDeploymentJsonTesting public deployment;
    string constant TEST_SALT = "DeploymentBasicTest";

    function setUp() public override {
        super.setUp();
        deployment = new MyDeploymentJsonTesting();
        _resetDeploymentLogs(TEST_SALT, "");
    }

    function _startDeployment(string memory network) internal {
        _prepareTestNetwork(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_Initialize() public view {
        // Verify session metadata is set correctly after start()
        assertEq(deployment.getString(deployment.SESSION_NETWORK()), "test_Initialize", "Network should match");
        assertEq(
            deployment.getAddress(deployment.SESSION_DEPLOYER()),
            address(deployment),
            "Deployer should be harness"
        );
        assertGt(deployment.getUint(deployment.SESSION_START_TIMESTAMP()), 0, "Start timestamp should be set");
        assertGt(deployment.getUint(deployment.SESSION_START_BLOCK()), 0, "Start block should be set");
    }

    function test_DeployContract() public {
        _startDeployment("test_DeployContract");
        
        address mockAddr = deployment.deployMockContract("mock1", "Mock Contract 1");

        assertTrue(mockAddr != address(0));
        assertTrue(deployment.has("mock1"));
        assertEq(deployment.get("mock1"), mockAddr);
        assertEq(uint(deployment.keyType("mock1")), uint(DataType.OBJECT));
    }

    function test_DeployMultipleContracts() public {
        _startDeployment("test_DeployMultipleContracts");
        
        address mock1 = deployment.deployMockContract("mock1", "Mock 1");
        address mock2 = deployment.deployMockContract("mock2", "Mock 2");
        address mock3 = deployment.deployMockContract("mock3", "Mock 3");

        assertNotEq(mock1, mock2);
        assertNotEq(mock2, mock3);

        assertTrue(deployment.has("mock1"));
        assertTrue(deployment.has("mock2"));
        assertTrue(deployment.has("mock3"));

        string[] memory keys = deployment.keys();
        assertEq(keys.length, 3);
    }

    function test_UseExistingContract() public {
        _startDeployment("test_UseExistingContract");
        
        address mock = address(new MockContract("Existing Mock"));
        deployment.useExisting("existing1", mock);

        assertTrue(deployment.has("existing1"));
        assertEq(deployment.get("existing1"), mock);
        assertEq(uint(deployment.keyType("existing1")), uint(DataType.OBJECT));
    }

    function test_Has() public {
        _startDeployment("test_Has");
        
        assertFalse(deployment.has("nonexistent"));

        deployment.deployMockContract("mock1", "Mock 1");

        assertTrue(deployment.has("mock1"));
        assertFalse(deployment.has("mock2"));
    }

    function test_Keys() public {
        _startDeployment("test_Keys");
        
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 0);

        deployment.deployMockContract("mock1", "Mock 1");
        deployment.deployMockContract("mock2", "Mock 2");

        keys = deployment.keys();
        assertEq(keys.length, 2);
        assertEq(keys[0], "mock1");
        assertEq(keys[1], "mock2");
    }

    function test_RevertWhen_InvalidAddress() public {
        _startDeployment("test_RevertWhen_InvalidAddress");
        
        // useExisting should reject address(0)
        vm.expectRevert();
        deployment.useExisting("invalid", address(0));
    }

    function test_Finish() public {
        _startDeployment("test_Finish");
        
        deployment.finish();

        assertGt(deployment.getUint(deployment.SESSION_FINISH_TIMESTAMP()), 0);
        assertGe(
            deployment.getUint(deployment.SESSION_FINISH_TIMESTAMP()),
            deployment.getUint(deployment.SESSION_START_TIMESTAMP())
        );
    }

    function test_RegisterExisting() public {
        _startDeployment("test_RegisterExisting");
        
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExisting("ExistingContract", existingContract);

        assertEq(deployment.get("ExistingContract"), existingContract);
        assertEq(uint(deployment.keyType("ExistingContract")), uint(DataType.OBJECT));
    }

    function test_RegisterExistingJsonSerialization() public {
        _startDeployment("test_RegisterExistingJsonSerialization");
        
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExisting("stETH", existingContract);
        deployment.finish();

        // Test deployment registration (JSON serialization requires DeploymentJson mixin)
        assertTrue(deployment.has("stETH"), "Should have stETH registered");
        assertEq(deployment.get("stETH"), existingContract, "Address should be accessible");
    }

    function test_RevertWhen_StartDeploymentTwice() public {
        _startDeployment("test_RevertWhen_StartDeploymentTwice");
        
        vm.expectRevert(Deployment.AlreadyInitialized.selector);
        deployment.start("test_RevertWhen_StartDeploymentTwice", TEST_SALT, "");
    }

    function test_RevertWhen_ActionWithoutInitialization() public {
        _startDeployment("test_RevertWhen_ActionWithoutInitialization");
        
        MyDeploymentJsonTesting fresh = new MyDeploymentJsonTesting();
        // Actions without initialization should fail (session not started)
        vm.expectRevert(Deployment.SessionNotStarted.selector);
        fresh.deployMockContract("mock", "Mock Contract");
    }

    // ============ Config Validation Tests ============

    function test_RevertWhen_ConfigMissingOwner() public {
        // Pass explicit empty config - no default owner
        _resetDeploymentLogs("MissingOwnerTest", "{}");
        _prepareTestNetwork("MissingOwnerTest", "test_RevertWhen_ConfigMissingOwner");
        
        MyDeploymentJsonTesting fresh = new MyDeploymentJsonTesting();
        fresh.start("test_RevertWhen_ConfigMissingOwner", "MissingOwnerTest", "");
        
        // Get the key before expectRevert to avoid it consuming the OWNER() call
        string memory ownerKey = fresh.OWNER();
        
        // Accessing owner should revert since it's not in the config
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "owner"));
        fresh.getAddress(ownerKey);
    }
}
