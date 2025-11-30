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
        addContract("contracts.mock1");
        addContract("contracts.mock2");
        addContract("contracts.mock3");
        addContract("contracts.existing1");
        addContract("contracts.ExistingContract");
        addContract("contracts.stETH");
        addContract("contracts.invalid");
        addContract("contracts.mock");
    }

    function deployMockContract(string memory key, string memory mockName) public returns (address) {
        MockContract mock = new MockContract(mockName);
        string memory fullKey = string.concat("contracts.", key);
        useExisting(fullKey, address(mock));
        return _get(fullKey);
    }

    function deployMockImplementation(string memory key, uint256 initValue) public returns (address) {
        MockImplementation impl = new MockImplementation();
        impl.initialize(initValue);
        string memory fullKey = string.concat("contracts.", key);
        registerContract(
            fullKey,
            address(impl),
            "MockImplementation",
            "test/mocks/basic/MockImplementation.sol",
            address(this)
        );
        _setUint(MOCK_IMPLEMENTATION_INIT_VALUE, initValue);
        return _get(fullKey);
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

    function test_Initialize() public {
        _startDeployment("test_Initialize");
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
        assertTrue(deployment.has("contracts.mock1"));
        assertEq(deployment.get("contracts.mock1"), mockAddr);
        assertEq(uint(deployment.keyType("contracts.mock1")), uint(DataType.OBJECT));
    }

    function test_DeployMultipleContracts() public {
        _startDeployment("test_DeployMultipleContracts");
        
        address mock1 = deployment.deployMockContract("mock1", "Mock 1");
        address mock2 = deployment.deployMockContract("mock2", "Mock 2");
        address mock3 = deployment.deployMockContract("mock3", "Mock 3");

        assertNotEq(mock1, mock2);
        assertNotEq(mock2, mock3);

        assertTrue(deployment.has("contracts.mock1"));
        assertTrue(deployment.has("contracts.mock2"));
        assertTrue(deployment.has("contracts.mock3"));
    }

    function test_UseExistingContract() public {
        _startDeployment("test_UseExistingContract");
        
        address mock = address(new MockContract("Existing Mock"));
        deployment.useExisting("contracts.existing1", mock);

        assertTrue(deployment.has("contracts.existing1"));
        assertEq(deployment.get("contracts.existing1"), mock);
        assertEq(uint(deployment.keyType("contracts.existing1")), uint(DataType.OBJECT));
    }

    function test_Has() public {
        _startDeployment("test_Has");
        
        assertFalse(deployment.has("nonexistent"));

        deployment.deployMockContract("mock1", "Mock 1");

        assertTrue(deployment.has("contracts.mock1"));
        assertFalse(deployment.has("contracts.mock2"));
    }

    function test_Keys() public {
        _startDeployment("test_Keys");
        
        // After start(), keys() returns only keys that have values
        // Session metadata is set automatically, but no contracts deployed yet
        string[] memory keys = deployment.keys();
        uint256 sessionKeyCount = keys.length;
        assertGt(sessionKeyCount, 0, "Session metadata keys should exist");
        
        // Verify no contract keys yet
        assertFalse(deployment.has("contracts.mock1"), "mock1 should not exist before deployment");
        assertFalse(deployment.has("contracts.mock2"), "mock2 should not exist before deployment");

        deployment.deployMockContract("mock1", "Mock 1");
        deployment.deployMockContract("mock2", "Mock 2");

        // After deploying contracts, keys should include the new contract keys
        keys = deployment.keys();
        assertGt(keys.length, sessionKeyCount, "Should have more keys after deploying contracts");
        assertTrue(deployment.has("contracts.mock1"), "mock1 should exist after deployment");
        assertTrue(deployment.has("contracts.mock2"), "mock2 should exist after deployment");
    }

    function test_UseExistingWithZeroAddress() public {
        _startDeployment("test_UseExistingWithZeroAddress");
        
        // useExisting allows address(0) - it's a valid use case for unset optional contracts
        deployment.useExisting("contracts.invalid", address(0));
        assertTrue(deployment.has("contracts.invalid"));
        assertEq(deployment.get("contracts.invalid"), address(0));
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

        deployment.useExisting("contracts.ExistingContract", existingContract);

        assertEq(deployment.get("contracts.ExistingContract"), existingContract);
        assertEq(uint(deployment.keyType("contracts.ExistingContract")), uint(DataType.OBJECT));
    }

    function test_RegisterExistingJsonSerialization() public {
        _startDeployment("test_RegisterExistingJsonSerialization");
        
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExisting("contracts.stETH", existingContract);
        deployment.finish();

        // Test deployment registration (JSON serialization requires DeploymentJson mixin)
        assertTrue(deployment.has("contracts.stETH"), "Should have stETH registered");
        assertEq(deployment.get("contracts.stETH"), existingContract, "Address should be accessible");
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
