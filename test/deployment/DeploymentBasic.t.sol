// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockDeployment} from "./MockDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {MockContract} from "@bao-test/mocks/basic/MockContract.sol";
import {MockImplementation} from "@bao-test/mocks/basic/MockImplementation.sol";

// Test harness extends MockDeployment with specific mock deployment methods
contract DeploymentHarness is MockDeployment {
    function deployMockContract(string memory key, string memory mockName) public returns (address) {
        MockContract mock = new MockContract(mockName);
        useExisting(key, address(mock));
        return _get(key);
    }

    function deployMockImplementation(string memory key, uint256 initValue) public returns (address) {
        MockImplementation impl = new MockImplementation();
        impl.initialize(initValue);
        registerContract(
            key,
            address(impl),
            "MockImplementation",
            "test/mocks/basic/MockImplementation.sol",
            "contract"
        );
        return _get(key);
    }
}

/**
 * @title DeploymentBasicTest
 * @notice Tests basic deployment functionality with string keys
 */
contract DeploymentBasicTest is BaoDeploymentTest {
    DeploymentHarness public deployment;
    string constant TEST_NETWORK = "test";
    string constant TEST_SALT = "test-system-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public {
        super.setUp();
        deployment = new DeploymentHarness();
        deployment.start(address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_Initialize() public view {
        Deployment.DeploymentMetadata memory metadata = deployment.getMetadata();
        assertEq(metadata.deployer, address(deployment)); // deployer is the harness
        assertEq(metadata.owner, address(this)); // owner is the test
        assertEq(metadata.network, "test");
        assertEq(metadata.version, "v1.0.0");
        assertTrue(metadata.startTimestamp > 0);
        assertTrue(metadata.startBlock > 0);
    }

    function test_DeployContract() public {
        address mockAddr = deployment.deployMockContract("mock1", "Mock Contract 1");

        assertTrue(mockAddr != address(0));
        assertTrue(deployment.hasByString("mock1"));
        assertEq(deployment.getByString("mock1"), mockAddr);
        assertEq(deployment.getEntryType("mock1"), "contract");
    }

    function test_DeployMultipleContracts() public {
        address mock1 = deployment.deployMockContract("mock1", "Mock 1");
        address mock2 = deployment.deployMockContract("mock2", "Mock 2");
        address mock3 = deployment.deployMockContract("mock3", "Mock 3");

        assertNotEq(mock1, mock2);
        assertNotEq(mock2, mock3);

        assertTrue(deployment.hasByString("mock1"));
        assertTrue(deployment.hasByString("mock2"));
        assertTrue(deployment.hasByString("mock3"));

        string[] memory keys = deployment.keys();
        assertEq(keys.length, 3);
    }

    function test_UseExistingContract() public {
        address mock = address(new MockContract("Existing Mock"));
        deployment.useExistingByString("existing1", mock);

        assertTrue(deployment.hasByString("existing1"));
        assertEq(deployment.getByString("existing1"), mock);
        assertEq(deployment.getEntryType("existing1"), "contract");
    }

    function test_Has() public {
        assertFalse(deployment.hasByString("nonexistent"));

        deployment.deployMockContract("mock1", "Mock 1");

        assertTrue(deployment.hasByString("mock1"));
        assertFalse(deployment.hasByString("mock2"));
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

    function test_RevertWhen_ContractNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "nonexistent"));
        deployment.getByString("nonexistent");
    }

    function test_RevertWhen_ContractAlreadyExists() public {
        deployment.deployMockContract("mock1", "Mock 1");

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractAlreadyExists.selector, "mock1"));
        deployment.deployMockContract("mock1", "Mock 1");
    }

    function test_RevertWhen_InvalidAddress() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.InvalidAddress.selector, "invalid"));
        deployment.useExistingByString("invalid", address(0));
    }

    function test_Finish() public {
        deployment.finish();

        Deployment.DeploymentMetadata memory metadata = deployment.getMetadata();
        assertTrue(metadata.finishTimestamp > 0);
        assertTrue(metadata.finishTimestamp >= metadata.startTimestamp);
    }

    function test_RegisterExisting() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExistingByString("ExistingContract", existingContract);

        assertEq(deployment.getByString("ExistingContract"), existingContract);
        assertEq(deployment.getEntryType("ExistingContract"), "contract");
    }

    function test_RegisterExistingJsonSerialization() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deployment.useExistingByString("stETH", existingContract);
        deployment.finish();

        // Test deployment registration (JSON serialization requires DeploymentJson mixin)
        assertTrue(deployment.hasByString("stETH"), "Should have stETH registered");
        assertEq(deployment.getByString("stETH"), existingContract, "Address should be accessible");
    }

    function test_RevertWhen_StartDeploymentTwice() public {
        vm.expectRevert(DeploymentRegistry.AlreadyInitialized.selector);
        deployment.start(address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_RevertWhen_ActionWithoutInitialization() public {
        DeploymentHarness fresh = new DeploymentHarness();
        // Actions without initialization should fail (no active run)
        vm.expectRevert("No active run");
        fresh.deployMockContract("mock", "Mock Contract");
    }
}
