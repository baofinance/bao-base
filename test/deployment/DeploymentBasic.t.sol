// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "./DeploymentJsonTesting.sol";

import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {MockContract} from "@bao-test/mocks/basic/MockContract.sol";
import {MockImplementation} from "@bao-test/mocks/basic/MockImplementation.sol";

// Test harness extends DeploymentJsonTesting with specific mock deployment methods
contract MyDeploymentJsonTesting is DeploymentJsonTesting {
    string constant MOCK_IMPLEMENTATION_INIT_VALUE = "mockImplementation.initValue";

    constructor() {
        addUintKey(MOCK_IMPLEMENTATION_INIT_VALUE);
    }

    function deployMockContract(string memory key, string memory mockName) public returns (address) {
        MockContract mock = new MockContract(mockName);
        useExisting(key, address(mock));
        return get(key);
    }

    function deployMockImplementation(string memory key, uint256 initValue) public returns (address) {
        MockImplementation impl = new MockImplementation();
        impl.initialize(initValue);
        registerImplementation(key, address(impl), "MockImplementation", "test/mocks/basic/MockImplementation.sol");
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
    string constant TEST_NETWORK = "test";
    string constant TEST_SALT = "test-system-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public override {
        super.setUp();
        deployment = new MyDeploymentJsonTesting();
        deployment.start(TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }
    /* TODO:

    function test_Initialize() public view {
        Deployment.DeploymentMetadata memory metadata = deployment.getMetadata();
        assertEq(metadata.deployer, address(deployment)); // deployer is the harness
        assertEq(metadata.owner, address(this)); // owner is the test
        assertEq(metadata.network, "test");
        assertEq(metadata.version, "v1.0.0");
        assertTrue(metadata.startTimestamp > 0);
        assertTrue(metadata.startBlock > 0);
    }
*/
    function test_DeployContract() public {
        address mockAddr = deployment.deployMockContract("mock1", "Mock Contract 1");

        assertTrue(mockAddr != address(0));
        assertTrue(deployment.has("mock1"));
        assertEq(deployment.get("mock1"), mockAddr);
        assertEq(uint(deployment.keyType("mock1")), uint(DataType.CONTRACT));
    }

    function test_DeployMultipleContracts() public {
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
        address mock = address(new MockContract("Existing Mock"));
        deployment.useExisting("existing1", mock);

        assertTrue(deployment.has("existing1"));
        assertEq(deployment.get("existing1"), mock);
        assertEq(uint(deployment.keyType("existing1")), uint(DataType.CONTRACT));
    }

    function test_Has() public {
        assertFalse(deployment.has("nonexistent"));

        deployment.deployMockContract("mock1", "Mock 1");

        assertTrue(deployment.has("mock1"));
        assertFalse(deployment.has("mock2"));
    }

    function test_Keys() public {
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 0);

        deployment.deployMockContract("mock1", "Mock 1");
        deployment.deployMockContract("mock2", "Mock 2");

        keys = deployment.keys();
        assertEq(keys.length, 2);
        assertEq(keys[0], "mock1");
        assertEq(keys[1], "mock2");
    }

    /* TODO:
    function test_RevertWhen_ContractNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(MyDeploymentJsonTesting.KeyNotRegistered.selector, "nonexistent"));
        deployment.get("nonexistent");
    }

    function test_RevertWhen_ContractAlreadyExists() public {
        deployment.deployMockContract("mock1", "Mock 1");

        vm.expectRevert(abi.encodeWithSelector(MyDeploymentJsonTesting.ContractAlreadyExists.selector, "mock1"));
        deployment.deployMockContract("mock1", "Mock 1");
    }

    function test_RevertWhen_InvalidAddress() public {
        vm.expectRevert(abi.encodeWithSelector(MyDeploymentJsonTesting.InvalidAddress.selector, "invalid"));
        deployment.useExisting("invalid", address(0));
    }
    */

    function test_Finish() public {
        deployment.finish();

        assertGt(deployment.getUint(deployment.SESSION_FINISH_TIMESTAMP), 0);
        assertGe(
            deployment.getUint(deployment.SESSION_FINISH_TIMESTAMP),
            deployment.getUint(deployment.SESSION_START_TIMESTAMP)
        );
    }

    function test_RegisterExisting() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExisting("ExistingContract", existingContract);

        assertEq(deployment.get("ExistingContract"), existingContract);
        assertEq(deployment.getType("ExistingContract"), "contract");
    }

    function test_RegisterExistingJsonSerialization() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExisting("stETH", existingContract);
        deployment.finish();

        // Test deployment registration (JSON serialization requires DeploymentJson mixin)
        assertTrue(deployment.has("stETH"), "Should have stETH registered");
        assertEq(deployment.get("stETH"), existingContract, "Address should be accessible");
    }

    function test_RevertWhen_StartDeploymentTwice() public {
        vm.expectRevert(Deployment.AlreadyInitialized.selector);
        deployment.start(TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_RevertWhen_ActionWithoutInitialization() public {
        MyDeploymentJsonTesting fresh = new MyDeploymentJsonTesting();
        // Actions without initialization should fail (no active run)
        vm.expectRevert("No active run");
        fresh.deployMockContract("mock", "Mock Contract");
    }
}
